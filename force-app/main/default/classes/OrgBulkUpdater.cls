public without sharing class OrgBulkUpdater {
    
    public static void updateAllRecordCurrency(String oldCurrency, String newCurrrency) {
        
        Savepoint sp = Database.setSavepoint();
        
        try {
            // ---- Expense__c ----
            List<Expense__c> exps = [
                SELECT Id, CurrencyIsoCode
                FROM Expense__c
                WHERE CurrencyIsoCode = :oldCurrency
            ];
            for (Expense__c e : exps) {
                e.CurrencyIsoCode = newCurrrency;
            }
            if (!exps.isEmpty()) {
                update exps;
            }
            System.debug('Updated Expense__c: ' + exps.size());
            
            // ---- Expense_Line_Item__c ----
            List<Expense_Line_Item__c> lines = [
                SELECT Id, CurrencyIsoCode
                FROM Expense_Line_Item__c
                WHERE CurrencyIsoCode = :oldCurrency
            ];
            for (Expense_Line_Item__c l : lines) {
                l.CurrencyIsoCode = newCurrrency;
            }
            if (!lines.isEmpty()) {
                update lines;
            }
            System.debug('Updated Expense_Line_Item__c: ' + lines.size());
            
            // ---- Visit__c (no currency field, but record still has CurrencyIsoCode) ----
            List<Visit__c> visits = [
                SELECT Id, CurrencyIsoCode
                FROM Visit__c
                WHERE CurrencyIsoCode = :oldCurrency
            ];
            for (Visit__c v : visits) {
                v.CurrencyIsoCode = newCurrrency;
            }
            if (!visits.isEmpty()) {
                update visits;
            }
            System.debug('Updated Visit__c: ' + visits.size());
            
            // ---- Task ----
            List<Task> tasks = [
                SELECT Id, CurrencyIsoCode
                FROM Task
                WHERE CurrencyIsoCode = :oldCurrency
            ];
            for (Task t : tasks) {
                t.CurrencyIsoCode = newCurrrency;
            }
            if (!tasks.isEmpty()) {
                update tasks;
            }
            System.debug('Updated Task: ' + tasks.size());
            
            // ---- Account ----
            List<Account> accts = [
                SELECT Id, CurrencyIsoCode
                FROM Account
                WHERE CurrencyIsoCode = :oldCurrency
            ];
            for (Account a : accts) {
                a.CurrencyIsoCode = newCurrrency;
            }
            if (!accts.isEmpty()) {
                update accts;
            }
            System.debug('Updated Account: ' + accts.size());
            
            System.debug('=== Currency flip completed successfully ===');
            
        } catch (Exception ex) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'Rollback. Error: ' + ex.getMessage() + '\n' + ex.getStackTraceString());
        }
    }
    
    public static void updateAllUsersToIndian() {
        // =====================================================================
        //  Indian-context user setup for Onco Global sandbox.
        //  - Locale/Timezone/Language/Currency → India
        //  - Company / Dept / Title → Onco standard
        //  - Address → randomized Bengaluru locations
        //  - CommunityNickname → FirstName (with auto-suffix on collision)
        // =====================================================================
        
        Savepoint sp = Database.setSavepoint();
        try {
            List<User> users = [
                SELECT Id, FirstName, LastName, CommunityNickname
                FROM User
                WHERE IsActive = true
                  AND UserType = 'Standard'
                  AND Profile.Name = 'System Administrator'
                  AND FirstName != null
                  AND Username NOT IN (
                      'epic.09b98e460238@orgfarm.salesforce.com'
                  )
            ];
        
            // Sample Bengaluru addresses — rotated across users
            List<Map<String,String>> addrs = new List<Map<String,String>>{
                new Map<String,String>{'s' => '42, 4th Cross, Indiranagar',     'p' => '560038'},
                new Map<String,String>{'s' => '15, Brigade Road',               'p' => '560001'},
                new Map<String,String>{'s' => '78, 100 Feet Road, Koramangala', 'p' => '560095'},
                new Map<String,String>{'s' => '23, Sector 4, HSR Layout',       'p' => '560102'},
                new Map<String,String>{'s' => '9, Whitefield Main Road',        'p' => '560066'},
                new Map<String,String>{'s' => '56, Jayanagar 4th Block',        'p' => '560011'}
            };
        
            // Pre-load existing nicknames from users NOT in our batch,
            // so we never collide with Guest Users / inactive users etc.
            Set<Id> targetIds = new Map<Id, User>(users).keySet();
            Set<String> usedNicks = new Set<String>();
            for (User other : [
                SELECT CommunityNickname
                FROM User
                WHERE CommunityNickname != NULL AND Id NOT IN :targetIds
            ]) {
                usedNicks.add(other.CommunityNickname.toLowerCase());
            }
        
            Integer i = 0;
            for (User u : users) {
                Map<String,String> addr = addrs[Math.mod(i, addrs.size())];
        
                u.CompanyName        = 'Onco Global';
                u.Department         = 'IT';
                u.Title              = 'System Administrator';
        
                u.Street             = addr.get('s');
                u.City               = 'Bengaluru';
                u.State              = 'Karnataka';
                u.PostalCode         = addr.get('p');
                u.Country            = 'India';
        
                u.TimeZoneSidKey         = 'Asia/Kolkata';
                u.LocaleSidKey           = 'en_IN';
                u.LanguageLocaleKey      = 'en_US';   // Salesforce has no en_IN language; en_US is standard
                u.DefaultCurrencyIsoCode = 'INR';
        
                // Nickname = FirstName, with collision-safe suffix
                if (String.isNotBlank(u.FirstName)) {
                    String baseNick = u.FirstName;
                    String nick     = baseNick;
                    Integer suffix  = 1;
                    while (usedNicks.contains(nick.toLowerCase())) {
                        nick = baseNick + suffix;
                        suffix++;
                    }
                    usedNicks.add(nick.toLowerCase());
                    u.CommunityNickname = nick;
                }
        
                i++;
            }
        
            update users;
            System.debug('=== Updated ' + users.size() + ' users successfully ===');
        
        } catch (Exception e) {
            Database.rollback(sp);
            System.debug(LoggingLevel.ERROR, 'Rolled back. Error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }
	}
    
    public static void createAffiliatiopns() {
        delete [SELECT Id FROM Doctor_Affiliation__c];
        
        // Person Account Ids (doctors)
        final Id DR_SHARMA_MUM   = '001ak000027jbofAAA'; // GP, Mumbai
        final Id DR_MEHTA_MUM    = '001ak000027jbogAAA'; // Gynec, Mumbai
        final Id DR_KUMAR_DEL    = '001ak000027jbohAAA'; // GP, Delhi
        final Id DR_REDDY_HYD    = '001ak000027jboiAAA'; // ENT, Hyderabad
        final Id DR_PATEL_PUNE   = '001ak000027jbojAAA'; // Pathologist, Pune
        final Id DR_IYER_CHE     = '001ak000027jbokAAA'; // Pediatrician, Chennai
        final Id DR_NAIR_BLR     = '001ak000027jbolAAA'; // GP, Bangalore
        final Id DR_GUPTA_DEL    = '001ak000027jbomAAA'; // Dermatologist, Delhi
        final Id DR_SINGH_KOL    = '001ak000027jbonAAA'; // Pulmonologist, Kolkata
        final Id DR_DESAI_BLR    = '001ak000027jbooAAA'; // Radiologist, Bangalore
        
        // Business Account Ids (facilities)
        final Id OG_MUMBAI       = '001ak000027jzqHAAQ';
        final Id OG_DELHI        = '001ak000027jzqIAAQ';
        final Id OG_BANGALORE    = '001ak000027jzqJAAQ';
        final Id OG_CHENNAI      = '001ak000027jzqKAAQ';
        final Id OG_HYDERABAD    = '001ak000027jzqLAAQ';
        final Id CITY_CARE_MUM   = '001ak000027jzqMAAQ';
        final Id LIFELINE_DEL    = '001ak000027jzqNAAQ';
        final Id SUNRISE_BLR     = '001ak000027jzqOAAQ';
        final Id PATEL_DIAG_PUNE = '001ak000027jzqPAAQ';
        final Id SHARMA_NH_KOL   = '001ak000027jzqQAAQ';
        
        List<Doctor_Affiliation__c> rows = new List<Doctor_Affiliation__c>{
            // Mumbai
            new Doctor_Affiliation__c(Doctor__c = DR_SHARMA_MUM, Facility__c = CITY_CARE_MUM,   Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_SHARMA_MUM, Facility__c = OG_MUMBAI,       Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_MEHTA_MUM,  Facility__c = CITY_CARE_MUM,   Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_MEHTA_MUM,  Facility__c = OG_MUMBAI,       Active__c = true),
            // Delhi
            new Doctor_Affiliation__c(Doctor__c = DR_KUMAR_DEL,  Facility__c = LIFELINE_DEL,    Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_KUMAR_DEL,  Facility__c = OG_DELHI,        Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_GUPTA_DEL,  Facility__c = LIFELINE_DEL,    Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_GUPTA_DEL,  Facility__c = OG_DELHI,        Active__c = true),
            // Bangalore
            new Doctor_Affiliation__c(Doctor__c = DR_NAIR_BLR,   Facility__c = SUNRISE_BLR,     Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_NAIR_BLR,   Facility__c = OG_BANGALORE,    Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_DESAI_BLR,  Facility__c = OG_BANGALORE,    Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_DESAI_BLR,  Facility__c = SUNRISE_BLR,     Active__c = true),
            // Single-affiliation doctors
            new Doctor_Affiliation__c(Doctor__c = DR_REDDY_HYD,  Facility__c = OG_HYDERABAD,    Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_IYER_CHE,   Facility__c = OG_CHENNAI,      Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_SINGH_KOL,  Facility__c = SHARMA_NH_KOL,   Active__c = true),
            // Pune (cross-region referral relationship)
            new Doctor_Affiliation__c(Doctor__c = DR_PATEL_PUNE, Facility__c = PATEL_DIAG_PUNE, Active__c = true),
            new Doctor_Affiliation__c(Doctor__c = DR_PATEL_PUNE, Facility__c = OG_MUMBAI,       Active__c = true)
        };
        
        insert rows;
        System.debug('Inserted ' + rows.size() + ' Doctor_Affiliation__c records.');
        
        // Verification
        for (AggregateResult ar : [
            SELECT Doctor__r.Name doctorName, COUNT(Id) cnt
            FROM Doctor_Affiliation__c
            WHERE Active__c = true
            GROUP BY Doctor__r.Name
            ORDER BY Doctor__r.Name
        ]) {
            System.debug(ar.get('doctorName') + ' → ' + ar.get('cnt') + ' affiliations');
        }
    }
}