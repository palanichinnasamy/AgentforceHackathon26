/**
 * VisitLoggerController
 * Apex controller for Visit Logger components.
 *
 * NOTE: Suggestion building now happens in LWC (and later in Agent topics).
 * This class only handles:
 *   - Dashboard stats
 *   - Field Set metadata
 *   - Recent visits query
 *   - Quick save (Skip button)
 *   - Transcript summarization via Prompt Template
 */
public with sharing class VisitLoggerController {

    @AuraEnabled(cacheable=true)
    public static Map<String, Object> getDashboardStats() {
        Id userId = UserInfo.getUserId();

        Integer visitsThisWeek = [
            SELECT COUNT()
            FROM Visit__c
            WHERE Sales_Rep__c = :userId
              AND Visit_Date__c = THIS_WEEK
        ];

        Integer visitsThisMonth = [
            SELECT COUNT()
            FROM Visit__c
            WHERE Sales_Rep__c = :userId
              AND Visit_Date__c = THIS_MONTH
        ];

        Integer openTasks = [
            SELECT COUNT()
            FROM Task
            WHERE OwnerId = :userId
              AND IsClosed = false
        ];

        AggregateResult[] expAgg = [
            SELECT SUM(Total_Amount_Spent__c) total
            FROM Expense__c
            WHERE CreatedById = :userId
              AND CreatedDate = THIS_MONTH
        ];
        Decimal expenseThisMonth = (expAgg != null && expAgg[0].get('total') != null)
            ? (Decimal) expAgg[0].get('total')
            : 0;

        return new Map<String, Object>{
            GlobalConstants.STAT_VISITS_THIS_WEEK   => visitsThisWeek,
            GlobalConstants.STAT_VISITS_THIS_MONTH  => visitsThisMonth,
            GlobalConstants.STAT_OPEN_TASKS         => openTasks,
            GlobalConstants.STAT_EXPENSE_THIS_MONTH => expenseThisMonth
        };
    }

    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getRecentVisitFieldSet() {
        List<Map<String, String>> fields = new List<Map<String, String>>();
        for (Schema.FieldSetMember f : Schema.SObjectType.Visit__c
                .fieldSets.getMap().get(GlobalConstants.FIELDSET_RECENT_VISIT_CARD).getFields()) {
            fields.add(new Map<String, String>{
                GlobalConstants.FIELDSET_KEY_PATH  => f.getFieldPath(),
                GlobalConstants.FIELDSET_KEY_LABEL => f.getLabel(),
                GlobalConstants.FIELDSET_KEY_TYPE  => String.valueOf(f.getType())
            });
        }
        return fields;
    }

    @AuraEnabled(cacheable=true)
    public static List<Visit__c> getRecentVisits() {
        Id userId = UserInfo.getUserId();

        Set<String> fieldPaths = new Set<String>{ 'Id', 'Name' };
        for (Schema.FieldSetMember f : Schema.SObjectType.Visit__c
                .fieldSets.getMap().get(GlobalConstants.FIELDSET_RECENT_VISIT_CARD).getFields()) {
            fieldPaths.add(f.getFieldPath());
        }

        if (fieldPaths.contains('Doctor__c')) {
            fieldPaths.add('Doctor__r.Name');
        }
        if (fieldPaths.contains('Provider__c')) {
            fieldPaths.add('Provider__r.Name');
        }
        if (fieldPaths.contains('Sales_Rep__c')) {
            fieldPaths.add('Sales_Rep__r.Name');
        }

        String soql = 'SELECT ' + String.join(new List<String>(fieldPaths), ', ')
            + ' FROM Visit__c'
            + ' WHERE Sales_Rep__c = :userId'
            + ' ORDER BY Visit_Date__c DESC NULLS LAST, CreatedDate DESC'
            + ' LIMIT 3';

        return Database.query(soql);
    }

    @AuraEnabled
    public static Map<String, Object> saveVisitQuick(
        String doctorId,
        String providerId,
        String visitNotes,
        String visitType,
        String audioTranscript
    ) {
        try {
            Visit__c v = new Visit__c();
            v.Doctor__c           = String.isNotBlank(doctorId)   ? doctorId   : null;
            v.Provider__c         = String.isNotBlank(providerId) ? providerId : null;
            v.Visit_Notes__c      = visitNotes;
            v.Audio_Transcript__c = audioTranscript;
            v.Visit_Date__c       = Date.today();
            v.End_Date__c         = Date.today();
            v.Sales_Rep__c        = UserInfo.getUserId();
            v.Visit_Type__c       = String.isNotBlank(visitType) ? visitType : GlobalConstants.VISIT_TYPE_MEETING;
            v.Status__c           = GlobalConstants.VISIT_STATUS_COMPLETED;
            insert v;

            return new Map<String, Object>{
                GlobalConstants.RESULT_KEY_SUCCESS    => true,
                GlobalConstants.RESULT_KEY_VISIT_ID   => v.Id,
                GlobalConstants.RESULT_KEY_VISIT_NAME => v.Name
            };
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Process raw voice transcript via Einstein Prompt Template
     * "Summarize_Visit_Transcript". Returns BOTH a cleaned 3rd-person summary
     * AND extracted entities for the suggestion cards.
     *
     * Inputs passed to the template:
     *   - transcript : raw voice transcript
     *   - today      : Date.today() in ISO format (for relative-date resolution)
     *   - userName   : current user's first name (to subject 3rd-person sentences)
     */
    @AuraEnabled
    public static Map<String, Object> processTranscript(String rawTranscript) {
        try {
            String llmResponse;

            try {
                ConnectApi.WrappedValue transcriptValue = new ConnectApi.WrappedValue();
                transcriptValue.value = rawTranscript;

                ConnectApi.WrappedValue todayValue = new ConnectApi.WrappedValue();
                todayValue.value = String.valueOf(Date.today());

                ConnectApi.WrappedValue userNameValue = new ConnectApi.WrappedValue();
                userNameValue.value = UserInfo.getFirstName();

                Map<String, ConnectApi.WrappedValue> inputParams =
                    new Map<String, ConnectApi.WrappedValue>();
                inputParams.put(GlobalConstants.PROMPT_INPUT_TRANSCRIPT, transcriptValue);
                inputParams.put(GlobalConstants.PROMPT_INPUT_TODAY,      todayValue);
                inputParams.put(GlobalConstants.PROMPT_INPUT_USER_NAME,  userNameValue);

                ConnectApi.EinsteinPromptTemplateGenerationsInput promptInput =
                    new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                promptInput.inputParams       = inputParams;
                promptInput.additionalConfig  = new ConnectApi.EinsteinLlmAdditionalConfigInput();
                promptInput.additionalConfig.applicationName  = GlobalConstants.PROMPT_APP_NAME;
                promptInput.additionalConfig.numGenerations   = 1;
                promptInput.additionalConfig.enablePiiMasking = false;
                promptInput.isPreview = false;

                ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                    ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                        GlobalConstants.PROMPT_TEMPLATE_SUMMARIZE_VISIT,
                        promptInput
                    );

                llmResponse = output.generations[0].text;
            } catch (Exception llmEx) {
                System.debug(LoggingLevel.WARN,
                    'LLM call failed, using fallback: ' + llmEx.getMessage());
                return fallbackResponse(rawTranscript);
            }

            return parseLlmResponse(llmResponse, rawTranscript);

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Re-extract entities from a user-edited summary via Einstein Prompt Template
     * "Generate_Suggestion_Card". Refreshes the suggestion cards WITHOUT
     * rewriting the summary itself (user owns the summary post-edit).
     *
     * Inputs passed to the template:
     *   - editedSummary : the user-edited visit summary
     *   - today         : Date.today() in ISO format (for relative-date resolution)
     */
    @AuraEnabled
    public static Map<String, Object> regenerateSuggestions(String editedSummary) {
        try {
            if (String.isBlank(editedSummary)) {
                return fallbackResponse(editedSummary);
            }

            String llmResponse;

            try {
                ConnectApi.WrappedValue summaryValue = new ConnectApi.WrappedValue();
                summaryValue.value = editedSummary;

                ConnectApi.WrappedValue todayValue = new ConnectApi.WrappedValue();
                todayValue.value = String.valueOf(Date.today());

                Map<String, ConnectApi.WrappedValue> inputParams =
                    new Map<String, ConnectApi.WrappedValue>();
                inputParams.put(GlobalConstants.PROMPT_INPUT_EDITED_SUMMARY, summaryValue);
                inputParams.put(GlobalConstants.PROMPT_INPUT_TODAY,          todayValue);

                ConnectApi.EinsteinPromptTemplateGenerationsInput promptInput =
                    new ConnectApi.EinsteinPromptTemplateGenerationsInput();
                promptInput.inputParams       = inputParams;
                promptInput.additionalConfig  = new ConnectApi.EinsteinLlmAdditionalConfigInput();
                promptInput.additionalConfig.applicationName  = GlobalConstants.PROMPT_APP_NAME;
                promptInput.additionalConfig.numGenerations   = 1;
                promptInput.additionalConfig.enablePiiMasking = false;
                promptInput.isPreview = false;

                ConnectApi.EinsteinPromptTemplateGenerationsRepresentation output =
                    ConnectApi.EinsteinLLM.generateMessagesForPromptTemplate(
                        GlobalConstants.PROMPT_TEMPLATE_REEXTRACT,
                        promptInput
                    );

                llmResponse = output.generations[0].text;
            } catch (Exception llmEx) {
                System.debug(LoggingLevel.WARN,
                    'LLM re-extract call failed, using fallback: ' + llmEx.getMessage());
                return fallbackResponse(editedSummary);
            }

            return parseLlmResponse(llmResponse, editedSummary);

        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Parse the JSON response from the LLM.
     * Falls back gracefully if JSON is malformed.
     */
    private static Map<String, Object> parseLlmResponse(String llmResponse, String rawTranscript) {
        Map<String, Object> result = new Map<String, Object>();
        result.put(GlobalConstants.LLM_KEY_STATUS, GlobalConstants.LLM_STATUS_SUCCESS);

        if (String.isBlank(llmResponse)) {
            return fallbackResponse(rawTranscript);
        }

        // Strip code fences if LLM wrapped the JSON
        String cleaned = llmResponse.trim();
        if (cleaned.startsWith(GlobalConstants.PROMPT_CODE_FENCE_JSON)) {
            cleaned = cleaned.substring(GlobalConstants.PROMPT_CODE_FENCE_JSON.length());
        } else if (cleaned.startsWith(GlobalConstants.PROMPT_CODE_FENCE)) {
            cleaned = cleaned.substring(GlobalConstants.PROMPT_CODE_FENCE.length());
        }
        if (cleaned.endsWith(GlobalConstants.PROMPT_CODE_FENCE)) {
            cleaned = cleaned.substring(0, cleaned.length() - GlobalConstants.PROMPT_CODE_FENCE.length());
        }
        cleaned = cleaned.trim();

        try {
            // Normalize unusual whitespace LLMs sometimes emit (NBSP, narrow NBSP, BOM, etc.)
            cleaned = cleaned.replaceAll('[\\u00A0\\u2007\\u202F\\uFEFF]', ' ');
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(cleaned);
            result.put(GlobalConstants.LLM_KEY_SUMMARY,             parsed.get(GlobalConstants.LLM_KEY_SUMMARY));
            result.put(GlobalConstants.LLM_KEY_DOCTOR_NAME,         stripSalutation((String) parsed.get(GlobalConstants.LLM_KEY_DOCTOR_NAME)));
            result.put(GlobalConstants.LLM_KEY_FACILITY_NAME,       parsed.get(GlobalConstants.LLM_KEY_FACILITY_NAME));
            result.put(GlobalConstants.LLM_KEY_TASK_SUBJECT,        parsed.get(GlobalConstants.LLM_KEY_TASK_SUBJECT));
            result.put(GlobalConstants.LLM_KEY_TASK_DUE_DATE,       parsed.get(GlobalConstants.LLM_KEY_TASK_DUE_DATE));
            result.put(GlobalConstants.LLM_KEY_EXPENSE_TYPE,        parsed.get(GlobalConstants.LLM_KEY_EXPENSE_TYPE));
            result.put(GlobalConstants.LLM_KEY_EXPENSE_AMOUNT,      parsed.get(GlobalConstants.LLM_KEY_EXPENSE_AMOUNT));
            result.put(GlobalConstants.LLM_KEY_EXPENSE_DESCRIPTION, parsed.get(GlobalConstants.LLM_KEY_EXPENSE_DESCRIPTION));
            result.put(GlobalConstants.LLM_KEY_VISIT_DATE,         parsed.get(GlobalConstants.LLM_KEY_VISIT_DATE));
            result.put(GlobalConstants.LLM_KEY_VISIT_DATE_ISO,      parsed.get(GlobalConstants.LLM_KEY_VISIT_DATE_ISO));
            result.put(GlobalConstants.LLM_KEY_TASK_DUE_DATE_ISO,    parsed.get(GlobalConstants.LLM_KEY_TASK_DUE_DATE_ISO));
            result.put(GlobalConstants.LLM_KEY_VISIT_CARD_DESC,   parsed.get(GlobalConstants.LLM_KEY_VISIT_CARD_DESC));
            result.put(GlobalConstants.LLM_KEY_TASK_CARD_DESC,    parsed.get(GlobalConstants.LLM_KEY_TASK_CARD_DESC));
            result.put(GlobalConstants.LLM_KEY_EXPENSE_CARD_DESC, parsed.get(GlobalConstants.LLM_KEY_EXPENSE_CARD_DESC));

            // Defensive cleanup — collapse duplicate "Dr." that LLM sometimes hallucinates
            String[] fieldsToClean = new String[]{
                GlobalConstants.LLM_KEY_SUMMARY,
                GlobalConstants.LLM_KEY_VISIT_CARD_DESC,
                GlobalConstants.LLM_KEY_TASK_SUBJECT,
                GlobalConstants.LLM_KEY_TASK_CARD_DESC,
                GlobalConstants.LLM_KEY_EXPENSE_DESCRIPTION,
                GlobalConstants.LLM_KEY_EXPENSE_CARD_DESC
            };
            for (String f : fieldsToClean) {
                Object v = result.get(f);
                if (v instanceof String) {
                    result.put(f, collapseDuplicateDr((String) v));
                }
            }
        } catch (Exception parseEx) {
            // LLM didn't return valid JSON — treat the whole response as the summary
            System.debug(LoggingLevel.WARN, 'JSON parse failed: ' + parseEx.getMessage());
            result.put(GlobalConstants.LLM_KEY_SUMMARY, cleaned);
        }

        return result;
    }

    /**
     * Fallback when LLM is unavailable.
     */
    private static Map<String, Object> fallbackResponse(String text) {
        if (String.isBlank(text)) {
            text = '';
        } else {
            text = text.trim().replaceAll('\\s+', ' ');
            if (text.length() > 1) {
                text = text.substring(0, 1).toUpperCase() + text.substring(1);
            }
            if (!text.endsWith('.') && !text.endsWith('!') && !text.endsWith('?')) {
                text += '.';
            }
        }

        return new Map<String, Object>{
            GlobalConstants.LLM_KEY_SUMMARY => text,
            GlobalConstants.LLM_KEY_STATUS  => GlobalConstants.LLM_STATUS_FALLBACK
        };
    }

    /**
     * Strips leading salutations (Dr., Mr., Mrs., Ms., Prof., Doctor) from a name.
     * LLMs frequently retain these even when instructed not to — defensive cleanup.
     */
    private static String stripSalutation(String name) {
        if (String.isBlank(name)) {
            return name;
        }
        return name.replaceAll('(?i)^(dr\\.?|mr\\.?|mrs\\.?|ms\\.?|prof\\.?|doctor)\\s+', '').trim();
    }

    /**
     * Collapses repeated "Dr"/"Dr." sequences anywhere in text → single "Dr. ".
     * Handles LLM artifacts like "Lunch with Dr. Dr Rajesh Sharma" → "Lunch with Dr. Rajesh Sharma".
     */
    private static String collapseDuplicateDr(String text) {
        if (String.isBlank(text)) {
            return text;
        }
        return text.replaceAll('(?i)\\b(dr\\.?\\s+){2,}', 'Dr. ');
    }
}