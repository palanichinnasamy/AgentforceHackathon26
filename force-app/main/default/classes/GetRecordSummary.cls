/**
 * GetRecordSummary
 * ----------------
 * Returns a hybrid summary (accurate totals + top-N record details)
 * for a Doctor (Person Account) or Facility (Business Account) the
 * user is asking about. Used by the "Record Summary and History"
 * topic on both Employee and Service agents.
 *
 * Output strategy ("hybrid"):
 *   - totalCount per object type from a separate COUNT() aggregate
 *     query so the agent can answer "how many visits did I have"
 *     accurately even if more than the detail cap exists.
 *   - topRecords per object type capped at TOP_RECORDS_LIMIT (10)
 *     for narrative detail.
 *
 * User filtering:
 *   - Caller passes runningUserId. Both agents must pass it:
 *       Employee Agent  -> $User.Id
 *       Service Agent   -> the User Id resolved via the WhatsApp
 *                          authorization flow (see Record Summary
 *                          topic instructions).
 *   - All queries are filtered by runningUserId so reps only see
 *     their own visits / tasks / expenses. Apex never reads
 *     UserInfo.getUserId() directly so the same code path works
 *     under Site Guest context.
 *
 * Time window:
 *   - timeWindow is one of the TW_* tokens. Default is THIS_YEAR
 *     when blank.
 *   - CUSTOM_DAYS uses customDays (positive integer).
 *
 * Empty handling:
 *   - When an object type has zero matching rows, totalCount = 0 and
 *     topRecords is an empty list. The agent should omit empty
 *     sections from the user-facing summary.
 */
public without sharing class GetRecordSummary {

    /* --------------------------------------------------------------- */
    /* Constants                                                       */
    /* --------------------------------------------------------------- */

    public static final String STATUS_SUCCESS  = 'Success';
    public static final String STATUS_NOTFOUND = 'NotFound';
    public static final String STATUS_ERROR    = 'Error';

    public static final String TW_LAST_7_DAYS  = 'LAST_7_DAYS';
    public static final String TW_LAST_30_DAYS = 'LAST_30_DAYS';
    public static final String TW_LAST_MONTH   = 'LAST_MONTH';
    public static final String TW_THIS_QUARTER = 'THIS_QUARTER';
    public static final String TW_THIS_YEAR    = 'THIS_YEAR';
    public static final String TW_ALL_TIME     = 'ALL_TIME';
    public static final String TW_CUSTOM_DAYS  = 'CUSTOM_DAYS';

    private static final Integer TOP_RECORDS_LIMIT  = 10;
    private static final Integer SCAN_QUERY_LIMIT   = 50;

    /* --------------------------------------------------------------- */
    /* DTOs                                                            */
    /* --------------------------------------------------------------- */

    public class Request {
        @InvocableVariable(label='Record Id' required=true
            description='Salesforce Id of the matched Doctor (Person Account) or Facility (Business Account). Resolve this via Query Records first; do not invent or guess.')
        public String recordId;

        @InvocableVariable(label='Running User Id'
            description='Optional. User Id whose history to summarize. Employee Agent: leave blank — Apex falls back to the running user automatically. Service Agent (WhatsApp): MUST pass the verifiedUserId resolved during the WhatsApp authorization flow, otherwise it will incorrectly default to the Site Guest User.')
        public String runningUserId;

        @InvocableVariable(label='Time Window'
            description='LAST_7_DAYS | LAST_30_DAYS | LAST_MONTH | THIS_QUARTER | THIS_YEAR | ALL_TIME | CUSTOM_DAYS. Default THIS_YEAR if blank. Pick based on user phrasing: "recent/this month" -> LAST_30_DAYS, "this week/yesterday/today" -> LAST_7_DAYS, "summary/recap/overview" -> THIS_YEAR, "all/everything/full/total" -> ALL_TIME, "last X days" -> CUSTOM_DAYS with customDays set.')
        public String timeWindow;

        @InvocableVariable(label='Custom Days'
            description='Number of trailing days, only when timeWindow = CUSTOM_DAYS. Must be a positive integer. Example: "last 60 days" -> 60.')
        public Integer customDays;
    }

    public class Response {
        @InvocableVariable(label='Status'
            description='Success | NotFound | Error. Success means the subject was resolved and counts were computed (counts may still be zero). NotFound means no Account exists for the given recordId. Error means an exception occurred — check errorMessage.')
        public String status;

        @InvocableVariable(label='Error Message'
            description='Populated only when status = Error or NotFound. Surface this to the user only when status is not Success.')
        public String errorMessage;

        // ---- Identification of the subject ---------------------------
        @InvocableVariable(label='Record Type'
            description='Doctor | Facility. Indicates whether the subject is a Person Account (Doctor) or Business Account (Facility / hospital / clinic). Use this to phrase the summary correctly.')
        public String recordType;

        @InvocableVariable(label='Record Name'
            description='Name of the doctor or facility being summarized. For doctors this is the full Person Account name; for facilities the Business Account Name.')
        public String recordName;

        @InvocableVariable(label='Record Detail'
            description='Single-line description of the subject (specialty / city) suitable for the agent header')
        public String recordDetail;

        // ---- Time window applied -------------------------------------
        @InvocableVariable(label='Time Window Applied'
            description='Echo of which window was applied. Useful for the agent to confirm scope in its reply.')
        public String timeWindowApplied;

        @InvocableVariable(label='From Date'
            description='Inclusive lower bound for date filters. Null when ALL_TIME.')
        public Date fromDate;

        // ---- Affiliations (Doctor input only) ------------------------
        @InvocableVariable(label='Affiliation Count'
            description='For Doctor input: number of active facility affiliations. Always 0 for Facility input.')
        public Integer affiliationCount;

        @InvocableVariable(label='Affiliation Names'
            description='Comma-separated list of affiliated facility names (Doctor input only).')
        public String affiliationNames;

        // ---- Visits --------------------------------------------------
        @InvocableVariable(label='Visit Total Count'
            description='Total number of Visit__c records logged by the running user with this Doctor or Facility within the applied time window. Use this for "how many visits" questions even if visitTopRecords is capped at 10.')
        public Integer visitTotalCount;

        @InvocableVariable(label='Visit Last Date'
            description='Date of the most recent Visit__c with this subject in the window. Null when visitTotalCount is 0. Use for "when was my last visit" questions.')
        public Date visitLastDate;

        @InvocableVariable(label='Visit Top Records'
            description='Up to 10 most recent visits in the window. Each entry is a single-line summary string.')
        public List<String> visitTopRecords;

        // ---- Tasks ---------------------------------------------------
        @InvocableVariable(label='Task Total Count'
            description='Total number of Task records owned by the running user and linked to this subject (WhatId) within the window. Includes both open and closed tasks.')
        public Integer taskTotalCount;

        @InvocableVariable(label='Task Open Count'
            description='Number of open tasks (not yet closed) within the window for this record + running user.')
        public Integer taskOpenCount;

        @InvocableVariable(label='Task Top Records'
            description='Up to 10 most recent tasks in the window. Each entry is a single-line summary string.')
        public List<String> taskTopRecords;

        // ---- Expenses ------------------------------------------------
        @InvocableVariable(label='Expense Total Count'
            description='Total number of Expense__c records linked (via Visit__c) to this subject within the window for the running user. Use for "how many expenses" questions.')
        public Integer expenseTotalCount;

        @InvocableVariable(label='Expense Total Spend'
            description='Sum of Total_Amount_Spent__c in INR across all expenses in the window for this record + running user.')
        public Decimal expenseTotalSpend;

        @InvocableVariable(label='Expense Top Records'
            description='Up to 10 most recent expenses in the window. Each entry is a single-line summary string.')
        public List<String> expenseTopRecords;
    }

    /* --------------------------------------------------------------- */
    /* Invocable entry point                                           */
    /* --------------------------------------------------------------- */

    @InvocableMethod(
        label='Get Record Summary'
        description='Returns aggregate counts plus the most recent 10 records (visits, tasks, expenses) for a Doctor (Person Account) or Facility (Business Account), filtered to the running user. Pass recordId and runningUserId; optionally set timeWindow (default THIS_YEAR) and customDays for CUSTOM_DAYS. Records past the cap are still counted in the totals so the agent can answer "how many" accurately.'
        category='Onco Field Agent')
    public static List<Response> getSummary(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response resp = new Response();
            try {
                processRequest(req, resp);
            } catch (Exception e) {
                resp.status = STATUS_ERROR;
                resp.errorMessage = e.getMessage();
                System.debug(LoggingLevel.ERROR,
                    'GetRecordSummary failed: ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
            }
            responses.add(resp);
        }

        return responses;
    }

    /* --------------------------------------------------------------- */
    /* Core orchestration                                              */
    /* --------------------------------------------------------------- */

    private static void processRequest(Request req, Response resp) {
        // Validate recordId — still required
        if (String.isBlank(req.recordId)) {
            resp.status = STATUS_ERROR;
            resp.errorMessage = 'recordId is required.';
            return;
        }

        Id recordIdSafe;
        try {
            recordIdSafe = Id.valueOf(req.recordId);
        } catch (Exception e) {
            resp.status = STATUS_ERROR;
            resp.errorMessage = 'Invalid recordId format: ' + e.getMessage();
            return;
        }

        // Resolve runningUserId:
        //   1. Try the value passed by the agent.
        //   2. If blank, literal "$User.Id", or unparseable, fall back to
        //      UserInfo.getUserId() — works for the Employee Agent which
        //      runs in the authenticated user's context.
        //   3. For Service Agent (Guest User), the topic instruction MUST
        //      pass a real verifiedUserId; the fallback would resolve to
        //      the Site Guest User which is wrong.
        Id runningUserIdSafe;
        String rawRunningUserId = req.runningUserId;
        if (String.isNotBlank(rawRunningUserId)
                && !'$User.Id'.equalsIgnoreCase(rawRunningUserId.trim())) {
            try {
                runningUserIdSafe = Id.valueOf(rawRunningUserId);
            } catch (Exception e) {
                runningUserIdSafe = null;
            }
        }
        if (runningUserIdSafe == null) {
            runningUserIdSafe = UserInfo.getUserId();
        }

        // Resolve subject (Doctor or Facility)
        Account subject = loadSubjectAccount(recordIdSafe);
        if (subject == null) {
            resp.status = STATUS_NOTFOUND;
            resp.errorMessage = 'No Account found for Id ' + recordIdSafe;
            return;
        }

        Boolean isDoctor = subject.IsPersonAccount;
        resp.recordType = isDoctor ? 'Doctor' : 'Facility';
        resp.recordName = subject.Name;
        resp.recordDetail = buildSubjectDetail(subject, isDoctor);

        // Resolve time window
        String windowToken = String.isBlank(req.timeWindow)
            ? TW_THIS_YEAR
            : req.timeWindow.trim().toUpperCase();
        Date fromDate = resolveFromDate(windowToken, req.customDays);
        resp.timeWindowApplied = windowToken;
        resp.fromDate = fromDate;

        // Affiliations are only meaningful for Doctor input
        if (isDoctor) {
            populateAffiliations(recordIdSafe, resp);
        } else {
            resp.affiliationCount = 0;
        }

        // Aggregations + top records per object type
        populateVisitSummary(recordIdSafe, isDoctor, runningUserIdSafe, fromDate, resp);
        populateTaskSummary(recordIdSafe, isDoctor, runningUserIdSafe, fromDate, resp);
        populateExpenseSummary(recordIdSafe, isDoctor, runningUserIdSafe, fromDate, resp);

        resp.status = STATUS_SUCCESS;
    }

    /* --------------------------------------------------------------- */
    /* Subject loader                                                  */
    /* --------------------------------------------------------------- */

    private static Account loadSubjectAccount(Id accountId) {
        List<Account> accs = [
            SELECT Id, Name, IsPersonAccount, PersonTitle,
                   PersonMobilePhone, PersonOtherPhone, Phone,
                   PersonEmail, BillingCity, BillingState, Type
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];
        return accs.isEmpty() ? null : accs[0];
    }

    private static String buildSubjectDetail(Account a, Boolean isDoctor) {
        if (isDoctor) {
            String specialty = String.isNotBlank(a.PersonTitle) ? a.PersonTitle : 'Specialty unknown';
            String contact   = bestDoctorContact(a);
            return contact == null
                ? specialty
                : specialty + ' | ' + contact;
        }
        // Facility
        String type = String.isNotBlank(a.Type) ? a.Type : 'Facility';
        String city = String.isNotBlank(a.BillingCity) ? a.BillingCity : 'Unknown city';
        return type + ', ' + city;
    }

    private static String bestDoctorContact(Account d) {
        if (String.isNotBlank(d.PersonMobilePhone)) {
            return d.PersonMobilePhone;
        }
        if (String.isNotBlank(d.PersonOtherPhone)) {
            return d.PersonOtherPhone;
        }
        if (String.isNotBlank(d.Phone)) {
            return d.Phone;
        }
        if (String.isNotBlank(d.PersonEmail)) {
            return d.PersonEmail;
        }
        return null;
    }

    /* --------------------------------------------------------------- */
    /* Time-window resolver                                            */
    /* --------------------------------------------------------------- */

    private static Date resolveFromDate(String window, Integer customDays) {
        Date today = Date.today();
        if (TW_LAST_7_DAYS.equals(window)) {
            return today.addDays(-7);
        }
        if (TW_LAST_30_DAYS.equals(window)) {
            return today.addDays(-30);
        }
        if (TW_LAST_MONTH.equals(window)) {
            // Previous calendar month, full month
            Date firstOfThisMonth = today.toStartOfMonth();
            return firstOfThisMonth.addMonths(-1);
        }
        if (TW_THIS_QUARTER.equals(window)) {
            Integer month = today.month();
            Integer firstMonthOfQuarter = ((month - 1) / 3) * 3 + 1;
            return Date.newInstance(today.year(), firstMonthOfQuarter, 1);
        }
        if (TW_THIS_YEAR.equals(window)) {
            return Date.newInstance(today.year(), 1, 1);
        }
        if (TW_ALL_TIME.equals(window)) {
            return null;
        }
        if (TW_CUSTOM_DAYS.equals(window)) {
            Integer days = (customDays != null && customDays > 0) ? customDays : 30;
            return today.addDays(-days);
        }
        // Unknown token -> default
        return Date.newInstance(today.year(), 1, 1);
    }

    /* --------------------------------------------------------------- */
    /* Affiliations (Doctor input only)                                */
    /* --------------------------------------------------------------- */

    private static void populateAffiliations(Id doctorId, Response resp) {
        List<Doctor_Affiliation__c> affs = [
            SELECT Facility__r.Name
            FROM Doctor_Affiliation__c
            WHERE Doctor__c = :doctorId
              AND Active__c = TRUE
            ORDER BY Facility__r.Name
        ];

        resp.affiliationCount = affs.size();

        if (affs.isEmpty()) {
            resp.affiliationNames = '';
            return;
        }

        List<String> names = new List<String>();
        for (Doctor_Affiliation__c a : affs) {
            if (a.Facility__r != null && String.isNotBlank(a.Facility__r.Name)) {
                names.add(a.Facility__r.Name);
            }
        }
        resp.affiliationNames = String.join(names, ', ');
    }

    /* --------------------------------------------------------------- */
    /* Visit summary                                                   */
    /* --------------------------------------------------------------- */

    private static void populateVisitSummary(Id recordIdSafe, Boolean isDoctor,
                                             Id runningUserIdSafe, Date fromDate,
                                             Response resp) {
        resp.visitTopRecords = new List<String>();

        String fkField = isDoctor ? 'Doctor__c' : 'Provider__c';

        String countSoql = 'SELECT COUNT() FROM Visit__c'
            + ' WHERE ' + fkField + ' = :recordIdSafe'
            + ' AND Sales_Rep__c = :runningUserIdSafe'
            + (fromDate == null ? '' : ' AND Visit_Date__c >= :fromDate');

        Integer total = Database.countQueryWithBinds(
            countSoql,
            new Map<String, Object>{
                'recordIdSafe' => recordIdSafe,
                'runningUserIdSafe' => runningUserIdSafe,
                'fromDate' => fromDate
            },
            AccessLevel.SYSTEM_MODE
        );
        resp.visitTotalCount = total;

        if (total == 0) {
            return;
        }

        String detailSoql = 'SELECT Id, Name, Visit_Date__c, Visit_Type__c, Visit_Notes__c,'
            + ' Doctor__r.Name, Provider__r.Name'
            + ' FROM Visit__c'
            + ' WHERE ' + fkField + ' = :recordIdSafe'
            + ' AND Sales_Rep__c = :runningUserIdSafe'
            + (fromDate == null ? '' : ' AND Visit_Date__c >= :fromDate')
            + ' ORDER BY Visit_Date__c DESC NULLS LAST, CreatedDate DESC'
            + ' LIMIT ' + TOP_RECORDS_LIMIT;

        List<Visit__c> visits = Database.queryWithBinds(
            detailSoql,
            new Map<String, Object>{
                'recordIdSafe' => recordIdSafe,
                'runningUserIdSafe' => runningUserIdSafe,
                'fromDate' => fromDate
            },
            AccessLevel.SYSTEM_MODE
        );

        for (Visit__c v : visits) {
            if (resp.visitLastDate == null && v.Visit_Date__c != null) {
                resp.visitLastDate = v.Visit_Date__c;
            }
            resp.visitTopRecords.add(formatVisitLine(v, isDoctor));
        }
    }

    private static String formatVisitLine(Visit__c v, Boolean parentIsDoctor) {
        String datePart = v.Visit_Date__c != null
            ? v.Visit_Date__c.format()
            : 'Date unknown';
        String typePart = String.isNotBlank(v.Visit_Type__c) ? v.Visit_Type__c : 'Visit';
        String contextPart = '';
        if (parentIsDoctor && v.Provider__c != null && v.Provider__r != null) {
            contextPart = ' at ' + v.Provider__r.Name;
        } else if (!parentIsDoctor && v.Doctor__c != null && v.Doctor__r != null) {
            contextPart = ' with ' + v.Doctor__r.Name;
        }
        String notesPart = String.isNotBlank(v.Visit_Notes__c)
            ? ' — ' + truncate(v.Visit_Notes__c, 120)
            : '';
        return datePart + ' [' + typePart + ']' + contextPart + notesPart;
    }

    /* --------------------------------------------------------------- */
    /* Task summary                                                    */
    /* --------------------------------------------------------------- */

    private static void populateTaskSummary(Id recordIdSafe, Boolean isDoctor,
                                            Id runningUserIdSafe, Date fromDate,
                                            Response resp) {
        resp.taskTopRecords = new List<String>();

        // Tasks are linked to the Doctor (or Facility) Account via WhatId
        // and owned by the running user.
        String countSoql = 'SELECT COUNT() FROM Task'
            + ' WHERE WhatId = :recordIdSafe'
            + ' AND OwnerId = :runningUserIdSafe'
            + (fromDate == null ? '' : ' AND CreatedDate >= :fromDateTime');

        Map<String, Object> binds = new Map<String, Object>{
            'recordIdSafe' => recordIdSafe,
            'runningUserIdSafe' => runningUserIdSafe
        };
        if (fromDate != null) {
            binds.put('fromDateTime', DateTime.newInstance(fromDate, Time.newInstance(0, 0, 0, 0)));
        }

        Integer total = Database.countQueryWithBinds(
            countSoql, binds, AccessLevel.SYSTEM_MODE
        );
        resp.taskTotalCount = total;

        if (total == 0) {
            resp.taskOpenCount = 0;
            return;
        }

        // Open count
        String openSoql = 'SELECT COUNT() FROM Task'
            + ' WHERE WhatId = :recordIdSafe'
            + ' AND OwnerId = :runningUserIdSafe'
            + ' AND IsClosed = FALSE'
            + (fromDate == null ? '' : ' AND CreatedDate >= :fromDateTime');
        resp.taskOpenCount = Database.countQueryWithBinds(
            openSoql, binds, AccessLevel.SYSTEM_MODE
        );

        // Top records
        String detailSoql = 'SELECT Id, Subject, Status, Priority, ActivityDate,'
            + ' IsClosed, Description, CreatedDate, What.Name'
            + ' FROM Task'
            + ' WHERE WhatId = :recordIdSafe'
            + ' AND OwnerId = :runningUserIdSafe'
            + (fromDate == null ? '' : ' AND CreatedDate >= :fromDateTime')
            + ' ORDER BY CreatedDate DESC'
            + ' LIMIT ' + TOP_RECORDS_LIMIT;

        List<Task> tasks = Database.queryWithBinds(
            detailSoql, binds, AccessLevel.SYSTEM_MODE
        );

        for (Task t : tasks) {
            resp.taskTopRecords.add(formatTaskLine(t));
        }
    }

    private static String formatTaskLine(Task t) {
        String dueOrCreated = t.ActivityDate != null
            ? 'due ' + t.ActivityDate.format()
            : 'created ' + t.CreatedDate.date().format();
        String statusPart = String.isNotBlank(t.Status) ? t.Status : (t.IsClosed ? 'Closed' : 'Open');
        String priorityPart = String.isNotBlank(t.Priority) && !'Normal'.equals(t.Priority)
            ? ' [' + t.Priority + ']'
            : '';
        String subj = String.isNotBlank(t.Subject) ? t.Subject : '(no subject)';
        return subj + priorityPart + ' (' + statusPart + ', ' + dueOrCreated + ')';
    }

    /* --------------------------------------------------------------- */
    /* Expense summary                                                 */
    /* --------------------------------------------------------------- */

    /**
     * Expense__c does NOT have a direct Doctor or Facility lookup —
     * it's linked to a Visit (Visit__c). To attribute expenses to a
     * doctor or facility, we first find the matching Visit Ids for
     * the running user, then query expenses that point to those visits.
     */
    private static void populateExpenseSummary(Id recordIdSafe, Boolean isDoctor,
                                               Id runningUserIdSafe, Date fromDate,
                                               Response resp) {
        resp.expenseTopRecords = new List<String>();
        resp.expenseTotalCount = 0;
        resp.expenseTotalSpend = 0;

        // Find related Visit Ids (filtered by running user already)
        String visitFk = isDoctor ? 'Doctor__c' : 'Provider__c';
        String visitSoql = 'SELECT Id FROM Visit__c'
            + ' WHERE ' + visitFk + ' = :recordIdSafe'
            + ' AND Sales_Rep__c = :runningUserIdSafe'
            + (fromDate == null ? '' : ' AND Visit_Date__c >= :fromDate')
            + ' LIMIT ' + SCAN_QUERY_LIMIT;

        List<Visit__c> linkedVisits = Database.queryWithBinds(
            visitSoql,
            new Map<String, Object>{
                'recordIdSafe' => recordIdSafe,
                'runningUserIdSafe' => runningUserIdSafe,
                'fromDate' => fromDate
            },
            AccessLevel.SYSTEM_MODE
        );

        if (linkedVisits.isEmpty()) {
            return;
        }

        Set<Id> visitIds = new Set<Id>();
        for (Visit__c v : linkedVisits) {
            visitIds.add(v.Id);
        }

        // Total count + sum (separate aggregate so we get accurate totals
        // even if more than TOP_RECORDS_LIMIT expenses exist).
        AggregateResult[] aggs = [
            SELECT COUNT(Id) total, SUM(Total_Amount_Spent__c) spend
            FROM Expense__c
            WHERE Visit__c IN :visitIds
        ];
        if (!aggs.isEmpty()) {
            Integer total = (Integer) aggs[0].get('total');
            Decimal spend = (Decimal) aggs[0].get('spend');
            resp.expenseTotalCount = total == null ? 0 : total;
            resp.expenseTotalSpend = spend == null ? 0 : spend;
        }

        if (resp.expenseTotalCount == 0) {
            return;
        }

        // Top records
        List<Expense__c> expenses = [
            SELECT Id, Name, Total_Amount_Spent__c, Expense_Type__c,
                   Transaction_Date__c, Vendor_Store__c, Visit__r.Name, CreatedDate
            FROM Expense__c
            WHERE Visit__c IN :visitIds
            ORDER BY Transaction_Date__c DESC NULLS LAST, CreatedDate DESC
            LIMIT :TOP_RECORDS_LIMIT
        ];

        for (Expense__c e : expenses) {
            resp.expenseTopRecords.add(formatExpenseLine(e));
        }
    }

    private static String formatExpenseLine(Expense__c e) {
        String datePart = e.Transaction_Date__c != null
            ? e.Transaction_Date__c.format()
            : e.CreatedDate.date().format();
        String amountPart = e.Total_Amount_Spent__c != null
            ? 'Rs. ' + String.valueOf(e.Total_Amount_Spent__c)
            : 'Amount not set';
        String typePart = String.isNotBlank(e.Expense_Type__c) ? e.Expense_Type__c : 'Expense';
        String namePart = String.isNotBlank(e.Name) ? e.Name : '(unnamed)';
        String vendorPart = String.isNotBlank(e.Vendor_Store__c) ? ' at ' + e.Vendor_Store__c : '';
        return datePart + ' — ' + namePart + ' (' + typePart + ', ' + amountPart + ')' + vendorPart;
    }

    /* --------------------------------------------------------------- */
    /* Utilities                                                       */
    /* --------------------------------------------------------------- */

    private static String truncate(String s, Integer max) {
        if (String.isBlank(s)) {
            return s;
        }
        if (s.length() <= max) {
            return s;
        }
        return s.substring(0, max) + '...';
    }
}