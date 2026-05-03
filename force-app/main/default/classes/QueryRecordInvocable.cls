/**
 * Single-entry invocable for record lookups exposed to Agentforce.
 *
 * Why one method:
 *   Salesforce permits only one @InvocableMethod per class. The agent
 *   passes 'objectType' to route to the right finder logic.
 *
 * Sharing: 'without sharing' so the same class works for both the
 *   Employee Agent (authenticated user) and the Service Agent
 *   (Site Guest User context, e.g. WhatsApp).
 *
 * Returned displayLabel is pre-formatted so the agent can render
 * a numbered list without further string manipulation.
 */
public without sharing class QueryRecordInvocable {

    /* --------------------------------------------------------------- */
    /* Object type tokens                                              */
    /* --------------------------------------------------------------- */
    public static final String TYPE_DOCTOR     = 'Doctor';
    public static final String TYPE_FACILITY   = 'Facility';
    public static final String TYPE_OPEN_TASKS = 'OpenTasks';
    public static final String TYPE_USER       = 'User';

    /* --------------------------------------------------------------- */
    /* Status tokens                                                   */
    /* --------------------------------------------------------------- */
    public static final String STATUS_SUCCESS  = 'Success';
    public static final String STATUS_NOTFOUND = 'NotFound';
    public static final String STATUS_TOOMANY  = 'TooMany';
    public static final String STATUS_ERROR    = 'Error';

    /* --------------------------------------------------------------- */
    /* Tunables                                                        */
    /* --------------------------------------------------------------- */
    private static final Integer HELPER_QUERY_LIMIT = 20;
    private static final Integer FINAL_RESULT_CAP   = 5;
    private static final Integer OPEN_TASKS_LIMIT   = 3;
    private static final Integer PHONE_MIN_DIGITS   = 4;
    private static final Integer PHONE_MAX_DIGITS   = 10;

    /* --------------------------------------------------------------- */
    /* DTOs                                                            */
    /* --------------------------------------------------------------- */

    public class Request {
        @InvocableVariable(label='Object Type' required=true
            description='Doctor | Facility | OpenTasks | Visit | User')
        public String objectType;

        @InvocableVariable(label='Search Name'
            description='Name fragment. Used for Doctor, Facility, and User lookups (full name).')
        public String searchName;

        @InvocableVariable(label='Search Phone'
            description='Phone number digits (last 4 to 10 digits). Used for Doctor and User lookups. Pass digits only — agent should strip prefixes like +91 and spaces before sending.')
        public String searchPhone;

        @InvocableVariable(label='Search Facility'
            description='Facility name to find affiliated doctors. Used for Doctor lookups via Doctor_Affiliation__c.')
        public String searchFacility;

        @InvocableVariable(label='Search Id'
            description='Record Id used as a filter. Used for OpenTasks (pass the doctor Account Id).')
        public String searchId;

        @InvocableVariable(label='Search Email'
            description='Email address. Used for User lookups (matches User.Email exactly, case-insensitive).')
        public String searchEmail;

        @InvocableVariable(label='Search Username'
            description='Salesforce username. Used for User lookups (matches User.Username exactly, case-insensitive).')
        public String searchUsername;
    }

    public class Response {
        @InvocableVariable(label='Status'
            description='Success | NotFound | TooMany | Error')
        public String status;

        @InvocableVariable(label='Match Count')
        public Integer matchCount;

        @InvocableVariable(label='Records')
        public List<RecordResult> records;

        @InvocableVariable(label='Error Message')
        public String errorMessage;
    }

    public class RecordResult {
        @InvocableVariable(label='Record Id')
        public String recordId;

        @InvocableVariable(label='Name')
        public String name;

        @InvocableVariable(label='Display Label'
            description='Pre-formatted label for numbered list display')
        public String displayLabel;

        @InvocableVariable(label='Secondary Info'
            description='Optional context (city, affiliations, phone)')
        public String secondaryInfo;
    }

    /* --------------------------------------------------------------- */
    /* Single invocable entry point                                    */
    /* --------------------------------------------------------------- */

    @InvocableMethod(
        label='Query Records'
        description='Look up records by name, phone, facility, email, username, or Id. Set objectType to Doctor (search by name and/or phone and/or facility), Facility (search by name), OpenTasks (search by Account Id), Visit (search by name), or User (search by name, phone, email, or username — used for WhatsApp user authorization). Returns up to 5 matches with pre-formatted displayLabel. Phone digits should be passed cleaned (last 4 to 10 digits, no +91 / spaces / dashes).'
        category='Onco Field Agent')
    public static List<Response> queryRecords(List<Request> requests) {
        List<Response> responses = new List<Response>();

        for (Request req : requests) {
            Response resp = new Response();
            resp.records = new List<RecordResult>();

            try {
                if (String.isBlank(req.objectType)) {
                    resp.status = STATUS_ERROR;
                    resp.errorMessage = 'objectType is required.';
                    responses.add(resp);
                    continue;
                }

                String objType = req.objectType.trim();

                if (TYPE_DOCTOR.equalsIgnoreCase(objType)) {
                    routeDoctorLookup(req, resp);
                } else if (TYPE_FACILITY.equalsIgnoreCase(objType)) {
                    if (String.isBlank(req.searchName)) {
                        resp.status = STATUS_ERROR;
                        resp.errorMessage = 'searchName is required for Facility lookups.';
                    } else {
                        findFacilities(req.searchName, resp);
                    }
                } else if (TYPE_OPEN_TASKS.equalsIgnoreCase(objType)) {
                    if (String.isBlank(req.searchId)) {
                        resp.status = STATUS_ERROR;
                        resp.errorMessage = 'searchId (Account Id) is required for OpenTasks lookups.';
                    } else {
                        findOpenTasksByAccount(req.searchId, resp);
                    }
                } else if (TYPE_USER.equalsIgnoreCase(objType)) {
                    routeUserLookup(req, resp);
                } else if(objType == 'Visit') {
                    if (String.isBlank(req.searchName)){
                        resp.status = STATUS_ERROR;
                        resp.errorMessage = 'searchName (Visit Name) is required for Visit query.';
                    } else {
                        findVisitRecord(req.searchName, resp);
                    }
                }
                else {
                    resp.status = STATUS_ERROR;
                    resp.errorMessage = 'Unsupported objectType: ' + objType
                        + '. Supported: Doctor, Facility, OpenTasks, Visit, User.';
                }

            } catch (Exception e) {
                resp.status = STATUS_ERROR;
                resp.errorMessage = e.getMessage();
                System.debug(LoggingLevel.ERROR,
                    'queryRecords failed: ' + e.getMessage()
                    + '\n' + e.getStackTraceString());
            }

            responses.add(resp);
        }

        return responses;
    }

    /* --------------------------------------------------------------- */
    /* Doctor routing — AND first, OR fallback                         */
    /* --------------------------------------------------------------- */

    private static void routeDoctorLookup(Request req, Response resp) {
        Boolean hasName     = String.isNotBlank(req.searchName);
        Boolean hasPhone    = String.isNotBlank(req.searchPhone);
        Boolean hasFacility = String.isNotBlank(req.searchFacility);

        if (!hasName && !hasPhone && !hasFacility) {
            resp.status = STATUS_ERROR;
            resp.errorMessage = 'At least one of searchName, searchPhone, or searchFacility is required for Doctor lookups.';
            return;
        }

        // Validate phone digits before querying
        String normalizedPhone = null;
        if (hasPhone) {
            normalizedPhone = normalizePhoneDigits(req.searchPhone);
            if (normalizedPhone == null || normalizedPhone.length() < PHONE_MIN_DIGITS) {
                resp.status = STATUS_ERROR;
                resp.errorMessage = 'Phone search needs at least ' + PHONE_MIN_DIGITS
                    + ' digits. Please ask the user for the full number or at least the last 4 digits.';
                return;
            }
        }

        // Run each search criterion that was provided
        Set<Id> nameMatches     = hasName     ? findDoctorsByName(req.searchName) : null;
        Set<Id> phoneMatches    = hasPhone    ? findDoctorsByPhone(normalizedPhone) : null;
        Set<Id> facilityMatches = hasFacility ? findDoctorsByFacility(req.searchFacility) : null;

        // AND first: intersect non-null sets
        Set<Id> finalIds = intersectNonNull(nameMatches, phoneMatches, facilityMatches);

        // OR fallback: union all non-null sets
        Boolean usedFallback = false;
        if (finalIds.isEmpty()) {
            finalIds = unionNonNull(nameMatches, phoneMatches, facilityMatches);
            if (!finalIds.isEmpty()) {
                usedFallback = true;
            }
        }

        if (finalIds.isEmpty()) {
            resp.status = STATUS_NOTFOUND;
            resp.matchCount = 0;
            return;
        }

        if (finalIds.size() > FINAL_RESULT_CAP) {
            resp.status = STATUS_TOOMANY;
            resp.matchCount = finalIds.size();
            return;
        }

        buildDoctorResults(finalIds, hasPhone, resp);

        if (usedFallback && resp.status == STATUS_SUCCESS) {
            // Inform agent that the result is a broader OR fallback
            resp.errorMessage = 'No exact match for all criteria. Showing partial matches.';
        }
    }

    private static Set<Id> intersectNonNull(Set<Id> a, Set<Id> b, Set<Id> c) {
        List<Set<Id>> sets = new List<Set<Id>>{ a, b, c };
        Set<Id> result = null;
        for (Set<Id> s : sets) {
            if (s == null) {
                continue;
            }
            if (result == null) {
                result = new Set<Id>(s);
            } else {
                result.retainAll(s);
            }
        }
        return result == null ? new Set<Id>() : result;
    }

    private static Set<Id> unionNonNull(Set<Id> a, Set<Id> b, Set<Id> c) {
        List<Set<Id>> sets = new List<Set<Id>>{ a, b, c };
        Set<Id> result = new Set<Id>();
        for (Set<Id> s : sets) {
            if (s != null) {
                result.addAll(s);
            }
        }
        return result;
    }

    /* --------------------------------------------------------------- */
    /* Doctor finders                                                  */
    /* --------------------------------------------------------------- */

    private static Set<Id> findDoctorsByName(String searchName) {
        Set<String> salutationsToStrip = new Set<String>{
            'dr', 'dr.', 'doctor',
            'mr', 'mr.', 'mrs', 'mrs.', 'ms', 'ms.', 'miss',
            'prof', 'prof.', 'professor'
        };

        List<String> rawTokens = searchName.trim().toLowerCase().split('\\s+');
        List<String> searchTokens = new List<String>();

        for (String token : rawTokens) {
            if (!salutationsToStrip.contains(token) && String.isNotBlank(token)) {
                searchTokens.add(token);
            }
        }

        if (searchTokens.isEmpty()) {
            return new Set<Id>();
        }

        List<String> whereClauses = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();
        for (Integer i = 0; i < searchTokens.size(); i++) {
            String paramName = 'token' + i;
            whereClauses.add('Name LIKE :' + paramName);
            bindMap.put(paramName, '%' + String.escapeSingleQuotes(searchTokens[i]) + '%');
        }

        String soql = 'SELECT Id FROM Account'
            + ' WHERE IsPersonAccount = TRUE'
            + ' AND ' + String.join(whereClauses, ' AND ')
            + ' LIMIT ' + HELPER_QUERY_LIMIT;

        List<Account> doctors = Database.queryWithBinds(
            soql, bindMap, AccessLevel.SYSTEM_MODE
        );

        Set<Id> result = new Set<Id>();
        for (Account d : doctors) {
            result.add(d.Id);
        }
        return result;
    }

    private static Set<Id> findDoctorsByPhone(String normalizedDigits) {
        // normalizedDigits is already cleaned (last 4-10 digits, no symbols)
        String phoneSearchToken = '%' + normalizedDigits + '%';

        List<Account> doctors = [
            SELECT Id
            FROM Account
            WHERE IsPersonAccount = TRUE
              AND (PersonMobilePhone LIKE :phoneSearchToken
                   OR PersonOtherPhone LIKE :phoneSearchToken
                   OR Phone LIKE :phoneSearchToken)
            LIMIT :HELPER_QUERY_LIMIT
        ];

        Set<Id> result = new Set<Id>();
        for (Account d : doctors) {
            result.add(d.Id);
        }
        return result;
    }

    private static Set<Id> findDoctorsByFacility(String facilityName) {
        String facilitySearchToken = '%' + String.escapeSingleQuotes(facilityName.trim()) + '%';

        Set<Id> facilityIds = new Set<Id>();
        for (Account facility : [
            SELECT Id
            FROM Account
            WHERE IsPersonAccount = FALSE
              AND Name LIKE :facilitySearchToken
            LIMIT :HELPER_QUERY_LIMIT
        ]) {
            facilityIds.add(facility.Id);
        }

        if (facilityIds.isEmpty()) {
            return new Set<Id>();
        }

        Set<Id> result = new Set<Id>();
        for (Doctor_Affiliation__c aff : [
            SELECT Doctor__c
            FROM Doctor_Affiliation__c
            WHERE Facility__c IN :facilityIds
              AND Active__c = TRUE
            LIMIT :HELPER_QUERY_LIMIT
        ]) {
            result.add(aff.Doctor__c);
        }
        return result;
    }

    /* --------------------------------------------------------------- */
    /* Doctor result builder                                           */
    /* --------------------------------------------------------------- */

    private static void buildDoctorResults(Set<Id> doctorIds, Boolean includePhone, Response resp) {
        List<Account> doctors = [
            SELECT Id, Name, Salutation, FirstName, LastName, PersonTitle,
                   PersonMobilePhone, PersonOtherPhone, Phone
            FROM Account
            WHERE Id IN :doctorIds
            ORDER BY LastName, FirstName
        ];

        Map<Id, List<String>> affiliationsByDoctor = new Map<Id, List<String>>();
        for (Doctor_Affiliation__c aff : [
            SELECT Doctor__c, Facility__r.Name
            FROM Doctor_Affiliation__c
            WHERE Doctor__c IN :doctorIds
              AND Active__c = TRUE
            ORDER BY Facility__r.Name
        ]) {
            if (!affiliationsByDoctor.containsKey(aff.Doctor__c)) {
                affiliationsByDoctor.put(aff.Doctor__c, new List<String>());
            }
            affiliationsByDoctor.get(aff.Doctor__c).add(aff.Facility__r.Name);
        }

        for (Account d : doctors) {
            RecordResult r = new RecordResult();
            r.recordId = d.Id;
            r.name = d.Name;

            List<String> facilities = affiliationsByDoctor.get(d.Id);
            String facilityPart = (facilities == null || facilities.isEmpty())
                ? 'No active affiliations'
                : String.join(facilities, ', ');

            String specialtyPart = String.isNotBlank(d.PersonTitle)
                ? ' — ' + d.PersonTitle
                : '';

            // Phone shown only when phone search was used
            String phonePart = '';
            if (includePhone) {
                String bestPhone = bestPhoneForDoctor(d);
                if (String.isNotBlank(bestPhone)) {
                    phonePart = ' | Phone: ' + bestPhone;
                }
            }

            r.displayLabel = d.Name + specialtyPart + ' (' + facilityPart + ')' + phonePart;
            r.secondaryInfo = facilityPart + phonePart;
            resp.records.add(r);
        }

        resp.status = STATUS_SUCCESS;
        resp.matchCount = doctors.size();
    }

    private static String bestPhoneForDoctor(Account d) {
        if (String.isNotBlank(d.PersonMobilePhone)) {
            return d.PersonMobilePhone;
        }
        if (String.isNotBlank(d.PersonOtherPhone)) {
            return d.PersonOtherPhone;
        }
        if (String.isNotBlank(d.Phone)) {
            return d.Phone;
        }
        return null;
    }

    /* --------------------------------------------------------------- */
    /* Phone normalization                                             */
    /* --------------------------------------------------------------- */

    /**
     * Strip all non-digit characters from the input, then keep only
     * the LAST 10 digits. Returns null if input has no digits.
     *
     *   "+91 98200 12345" -> "9820012345"
     *   "98200 12345"     -> "9820012345"
     *   "12345"           -> "12345"
     *   "1234"            -> "1234"
     *   "abc"             -> null
     */
    private static String normalizePhoneDigits(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        String digitsOnly = raw.replaceAll('[^0-9]', '');
        if (String.isBlank(digitsOnly)) {
            return null;
        }
        if (digitsOnly.length() > PHONE_MAX_DIGITS) {
            digitsOnly = digitsOnly.substring(digitsOnly.length() - PHONE_MAX_DIGITS);
        }
        return digitsOnly;
    }

    /* --------------------------------------------------------------- */
    /* Facility finder                                                 */
    /* --------------------------------------------------------------- */

    private static void findFacilities(String searchName, Response resp) {
        Set<String> noiseWords = new Set<String>{
            'the', 'a', 'an', 'hospital', 'clinic', 'center', 'centre',
            'medical', 'diagnostic', 'nursing', 'home'
        };

        List<String> rawTokens = searchName.trim().toLowerCase().split('\\s+');
        List<String> searchTokens = new List<String>();

        for (String token : rawTokens) {
            if (!noiseWords.contains(token) && String.isNotBlank(token)) {
                searchTokens.add(token);
            }
        }

        if (searchTokens.isEmpty()) {
            searchTokens.add(searchName.trim().toLowerCase());
        }

        List<String> whereClauses = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();
        for (Integer i = 0; i < searchTokens.size(); i++) {
            String paramName = 'token' + i;
            whereClauses.add('Name LIKE :' + paramName);
            bindMap.put(paramName, '%' + String.escapeSingleQuotes(searchTokens[i]) + '%');
        }

        String soql = 'SELECT Id, Name, Type, BillingCity, BillingState'
            + ' FROM Account'
            + ' WHERE IsPersonAccount = FALSE'
            + ' AND ' + String.join(whereClauses, ' AND ')
            + ' ORDER BY Name'
            + ' LIMIT 6';

        List<Account> facilities = Database.queryWithBinds(
            soql, bindMap, AccessLevel.SYSTEM_MODE
        );

        if (facilities.isEmpty()) {
            resp.status = STATUS_NOTFOUND;
            resp.matchCount = 0;
            return;
        }

        if (facilities.size() > FINAL_RESULT_CAP) {
            resp.status = STATUS_TOOMANY;
            resp.matchCount = facilities.size();
            return;
        }

        for (Account f : facilities) {
            RecordResult r = new RecordResult();
            r.recordId = f.Id;
            r.name = f.Name;

            String typePart = String.isNotBlank(f.Type) ? f.Type : 'Facility';
            String cityPart = String.isNotBlank(f.BillingCity)
                ? f.BillingCity
                : 'Unknown city';

            r.displayLabel = f.Name + ' — ' + typePart + ', ' + cityPart;
            r.secondaryInfo = cityPart;
            resp.records.add(r);
        }

        resp.status = STATUS_SUCCESS;
        resp.matchCount = facilities.size();
    }

    /* --------------------------------------------------------------- */
    /* Open Tasks finder                                               */
    /* --------------------------------------------------------------- */

    private static void findOpenTasksByAccount(String accountId, Response resp) {
        Id parsedId;
        try {
            parsedId = Id.valueOf(accountId);
        } catch (Exception e) {
            resp.status = STATUS_ERROR;
            resp.errorMessage = 'Invalid Account Id: ' + accountId;
            return;
        }

        List<Task> openTasks = [
            SELECT Id, Subject, ActivityDate, Priority, Status, Description
            FROM Task
            WHERE WhatId = :parsedId
              AND IsClosed = FALSE
            ORDER BY ActivityDate ASC NULLS LAST, CreatedDate DESC
            LIMIT :OPEN_TASKS_LIMIT
        ];

        if (openTasks.isEmpty()) {
            resp.status = STATUS_NOTFOUND;
            resp.matchCount = 0;
            return;
        }

        for (Task t : openTasks) {
            RecordResult r = new RecordResult();
            r.recordId = t.Id;
            r.name = t.Subject;

            String dueDatePart = (t.ActivityDate != null)
                ? t.ActivityDate.format()
                : 'no due date';
            String priorityPart = String.isNotBlank(t.Priority)
                ? ' [' + t.Priority + ']'
                : '';

            r.displayLabel = t.Subject + priorityPart + ' (due ' + dueDatePart + ')';
            r.secondaryInfo = (t.ActivityDate != null)
                ? String.valueOf(t.ActivityDate)
                : null;
            resp.records.add(r);
        }

        resp.status = STATUS_SUCCESS;
        resp.matchCount = openTasks.size();
    }

    /**
     * Visit lookup by name (LIKE match on Visit__c.Name).
     */
    private static void findVisitRecord(String visitName, Response resp){
        try {
            String visitNameNew = '%' + visitName + '%';
            Visit__c visitFound = [
                SELECT Id, Name
                FROM Visit__c
                WHERE NAME LIKE :visitNameNew
                LIMIT 1
            ];

            if(visitFound != null){

                resp.status = STATUS_SUCCESS;

                RecordResult r = new RecordResult();
                r.recordId = visitfound.Id;
                r.name = visitfound.name;

                resp.records.add(r);

            } else {
                resp.status = STATUS_NOTFOUND;
            }
        } catch(exception e){
            resp.status = STATUS_NOTFOUND;
            resp.errorMessage = e.getMessage();
        }
    }

    /* --------------------------------------------------------------- */
    /* User routing — AND first, OR fallback                           */
    /* --------------------------------------------------------------- */

    /**
     * Routes User identifier matching for WhatsApp authorization flow.
     * Accepts any combination of name, phone, email, or username and
     * returns up to 5 matching active Standard users. Used by the
     * Service Agent's Record Summary topic to verify the WhatsApp
     * sender's identity before exposing personal CRM history.
     */
    private static void routeUserLookup(Request req, Response resp) {
        Boolean hasName     = String.isNotBlank(req.searchName);
        Boolean hasPhone    = String.isNotBlank(req.searchPhone);
        Boolean hasEmail    = String.isNotBlank(req.searchEmail);
        Boolean hasUsername = String.isNotBlank(req.searchUsername);

        if (!hasName && !hasPhone && !hasEmail && !hasUsername) {
            resp.status = STATUS_ERROR;
            resp.errorMessage = 'At least one of searchName, searchPhone, searchEmail, or searchUsername is required for User lookups.';
            return;
        }

        // Validate phone digits before querying
        String normalizedPhone = null;
        if (hasPhone) {
            normalizedPhone = normalizePhoneDigits(req.searchPhone);
            if (normalizedPhone == null || normalizedPhone.length() < PHONE_MIN_DIGITS) {
                resp.status = STATUS_ERROR;
                resp.errorMessage = 'Phone search needs at least ' + PHONE_MIN_DIGITS
                    + ' digits. Please ask the user for the full number or at least the last 4 digits.';
                return;
            }
        }

        // Run each search criterion that was provided
        Set<Id> nameMatches     = hasName     ? findUsersByName(req.searchName)         : null;
        Set<Id> phoneMatches    = hasPhone    ? findUsersByPhone(normalizedPhone)       : null;
        Set<Id> emailMatches    = hasEmail    ? findUsersByEmail(req.searchEmail)       : null;
        Set<Id> usernameMatches = hasUsername ? findUsersByUsername(req.searchUsername) : null;

        // AND first: intersect non-null sets
        Set<Id> finalIds = intersectFourNonNull(nameMatches, phoneMatches, emailMatches, usernameMatches);

        // OR fallback: union all non-null sets
        Boolean usedFallback = false;
        if (finalIds.isEmpty()) {
            finalIds = unionFourNonNull(nameMatches, phoneMatches, emailMatches, usernameMatches);
            if (!finalIds.isEmpty()) {
                usedFallback = true;
            }
        }

        if (finalIds.isEmpty()) {
            resp.status = STATUS_NOTFOUND;
            resp.matchCount = 0;
            return;
        }

        if (finalIds.size() > FINAL_RESULT_CAP) {
            resp.status = STATUS_TOOMANY;
            resp.matchCount = finalIds.size();
            return;
        }

        buildUserResults(finalIds, resp);

        if (usedFallback && resp.status == STATUS_SUCCESS) {
            resp.errorMessage = 'No exact match for all criteria. Showing partial matches.';
        }
    }

    /**
     * Four-set intersection helper for User lookup AND path.
     */
    private static Set<Id> intersectFourNonNull(Set<Id> a, Set<Id> b, Set<Id> c, Set<Id> d) {
        List<Set<Id>> sets = new List<Set<Id>>{ a, b, c, d };
        Set<Id> result = null;
        for (Set<Id> s : sets) {
            if (s == null) {
                continue;
            }
            if (result == null) {
                result = new Set<Id>(s);
            } else {
                result.retainAll(s);
            }
        }
        return result == null ? new Set<Id>() : result;
    }

    /**
     * Four-set union helper for User lookup OR fallback path.
     */
    private static Set<Id> unionFourNonNull(Set<Id> a, Set<Id> b, Set<Id> c, Set<Id> d) {
        List<Set<Id>> sets = new List<Set<Id>>{ a, b, c, d };
        Set<Id> result = new Set<Id>();
        for (Set<Id> s : sets) {
            if (s != null) {
                result.addAll(s);
            }
        }
        return result;
    }

    /* --------------------------------------------------------------- */
    /* User finders                                                    */
    /* --------------------------------------------------------------- */

    /**
     * Token-based name search across User.Name (FirstName + LastName).
     */
    private static Set<Id> findUsersByName(String searchName) {
        List<String> rawTokens = searchName.trim().toLowerCase().split('\\s+');
        List<String> searchTokens = new List<String>();

        for (String token : rawTokens) {
            if (String.isNotBlank(token)) {
                searchTokens.add(token);
            }
        }

        if (searchTokens.isEmpty()) {
            return new Set<Id>();
        }

        List<String> whereClauses = new List<String>();
        Map<String, Object> bindMap = new Map<String, Object>();
        for (Integer i = 0; i < searchTokens.size(); i++) {
            String paramName = 'token' + i;
            whereClauses.add('Name LIKE :' + paramName);
            bindMap.put(paramName, '%' + String.escapeSingleQuotes(searchTokens[i]) + '%');
        }

        String soql = 'SELECT Id FROM User'
            + ' WHERE IsActive = TRUE'
            + ' AND UserType = \'Standard\''
            + ' AND ' + String.join(whereClauses, ' AND ')
            + ' LIMIT ' + HELPER_QUERY_LIMIT;

        List<User> users = Database.queryWithBinds(
            soql, bindMap, AccessLevel.SYSTEM_MODE
        );

        Set<Id> result = new Set<Id>();
        for (User u : users) {
            result.add(u.Id);
        }
        return result;
    }

    /**
     * Phone suffix match across User.Whatsapp_Number__c and User.Phone.
     */
    private static Set<Id> findUsersByPhone(String normalizedDigits) {
        String phoneSearchToken = '%' + normalizedDigits + '%';

        List<User> users = [
            SELECT Id
            FROM User
            WHERE IsActive = TRUE
              AND UserType = 'Standard'
              AND (Whatsapp_Number__c LIKE :phoneSearchToken
                   OR Phone LIKE :phoneSearchToken)
            LIMIT :HELPER_QUERY_LIMIT
        ];

        Set<Id> result = new Set<Id>();
        for (User u : users) {
            result.add(u.Id);
        }
        return result;
    }

    /**
     * Exact email match (case-insensitive comparison via lowercased token).
     */
    private static Set<Id> findUsersByEmail(String email) {
        String normalized = email.trim().toLowerCase();

        List<User> users = [
            SELECT Id
            FROM User
            WHERE IsActive = TRUE
              AND UserType = 'Standard'
              AND Email = :normalized
            LIMIT :HELPER_QUERY_LIMIT
        ];

        Set<Id> result = new Set<Id>();
        for (User u : users) {
            result.add(u.Id);
        }
        return result;
    }

    /**
     * Exact username match (case-insensitive comparison via lowercased token).
     */
    private static Set<Id> findUsersByUsername(String username) {
        String normalized = username.trim().toLowerCase();

        List<User> users = [
            SELECT Id
            FROM User
            WHERE IsActive = TRUE
              AND UserType = 'Standard'
              AND Username = :normalized
            LIMIT :HELPER_QUERY_LIMIT
        ];

        Set<Id> result = new Set<Id>();
        for (User u : users) {
            result.add(u.Id);
        }
        return result;
    }

    /**
     * Builds RecordResult entries for matched users with a displayLabel
     * formatted to help the agent verify identity at a glance:
     *   "Rishav Maji — rmaji@awt26.hackathon | +91 75848 65889"
     */
    private static void buildUserResults(Set<Id> userIds, Response resp) {
        List<User> users = [
            SELECT Id, Name, FirstName, LastName, Username, Email,
                   Phone, Whatsapp_Number__c, Title, Department
            FROM User
            WHERE Id IN :userIds
            ORDER BY LastName, FirstName
        ];

        for (User u : users) {
            RecordResult r = new RecordResult();
            r.recordId = u.Id;
            r.name = u.Name;

            String emailPart = String.isNotBlank(u.Email)
                ? ' — ' + u.Email
                : '';

            String bestPhone = bestPhoneForUser(u);
            String phonePart = String.isNotBlank(bestPhone)
                ? ' | ' + bestPhone
                : '';

            r.displayLabel = u.Name + emailPart + phonePart;
            r.secondaryInfo = u.Username;
            resp.records.add(r);
        }

        resp.status = STATUS_SUCCESS;
        resp.matchCount = users.size();
    }

    private static String bestPhoneForUser(User u) {
        if (String.isNotBlank(u.Whatsapp_Number__c)) {
            return u.Whatsapp_Number__c;
        }
        if (String.isNotBlank(u.Phone)) {
            return u.Phone;
        }
        return null;
    }
}