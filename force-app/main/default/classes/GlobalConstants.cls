/**
 * Centralized constants for ALL Apex classes in the org.
 * Includes constants for the Onco Field Agent app (mobile/desktop),
 * WhatsApp integration, and any future functionality.
 */
public class GlobalConstants {

    /* ============================================================== */
    /* SHARED — AGENTFORCE                                            */
    /* ============================================================== */

    /* ---------------- Agent API Name Configuration -------------------- */
    public static final String EMPLOYEE_AGENT_API_NAME = 'OncoGlobally_Sales_AI_Employee_Agent';
    public static final String SERVICE_AGENT_API_NAME  = 'OncoGlobally_Sales_AI_Service_Agent';
    public static final String INVOCABLE_ACTION_NAME   = 'generateAiAgentResponse';
    public static final String AGENT_PARAM_USER_MSG    = 'userMessage';
    public static final String AGENT_PARAM_SESSION     = 'sessionId';
    public static final String AGENT_PARAM_RESPONSE    = 'agentResponse';

    /* ---------------- Agent response parsing -------------------------- */
    public static final String AGENT_RESP_VALUE_KEY = 'value';

    /* ============================================================== */
    /* ONCO FIELD AGENT APP                                           */
    /* ============================================================== */

    /* ---------------- Visit picklist values --------------------------- */
    public static final String VISIT_TYPE_MEETING     = 'Meeting';
    public static final String VISIT_STATUS_COMPLETED = 'Completed';

    /* ---------------- Field Set names --------------------------------- */
    public static final String FIELDSET_RECENT_VISIT_CARD = 'Recent_Visit_Card';

    /* ---------------- Field Set output keys --------------------------- */
    public static final String FIELDSET_KEY_PATH  = 'fieldPath';
    public static final String FIELDSET_KEY_LABEL = 'label';
    public static final String FIELDSET_KEY_TYPE  = 'type';

    /* ---------------- Einstein Prompt Template ------------------------ */
    public static final String PROMPT_TEMPLATE_SUMMARIZE_VISIT = 'Summarize_Visit_Transcript';
    public static final String PROMPT_TEMPLATE_REEXTRACT       = 'Generate_Suggestion_Card';
    public static final String PROMPT_INPUT_TRANSCRIPT         = 'Input:transcript';
    public static final String PROMPT_APP_NAME                 = 'PromptBuilderPreview';
    public static final String PROMPT_CODE_FENCE_JSON          = '```json';
    public static final String PROMPT_CODE_FENCE               = '```';
    public static final String PROMPT_INPUT_EDITED_SUMMARY     = 'Input:editedSummary';
    public static final String PROMPT_INPUT_TODAY              = 'Input:today';
    public static final String PROMPT_INPUT_USER_NAME          = 'Input:userName';

    /* ---------------- LLM response keys (contract with LWC) ----------- */
    public static final String LLM_KEY_STATUS              = 'status';
    public static final String LLM_KEY_SUMMARY             = 'summary';
    public static final String LLM_KEY_DOCTOR_NAME         = 'doctorName';
    public static final String LLM_KEY_FACILITY_NAME       = 'facilityName';
    public static final String LLM_KEY_TASK_SUBJECT        = 'taskSubject';
    public static final String LLM_KEY_TASK_DUE_DATE       = 'taskDueDate';
    public static final String LLM_KEY_EXPENSE_TYPE        = 'expenseType';
    public static final String LLM_KEY_EXPENSE_AMOUNT      = 'expenseAmount';
    public static final String LLM_KEY_EXPENSE_DESCRIPTION = 'expenseDescription';
    public static final String LLM_KEY_VISIT_DATE         = 'visitDate';
    public static final String LLM_KEY_VISIT_DATE_ISO     = 'visitDateISO';
    public static final String LLM_KEY_TASK_DUE_DATE_ISO  = 'taskDueDateISO';
    public static final String LLM_KEY_VISIT_CARD_DESC   = 'visitCardDescription';
    public static final String LLM_KEY_TASK_CARD_DESC    = 'taskCardDescription';
    public static final String LLM_KEY_EXPENSE_CARD_DESC = 'expenseCardDescription';

    /* ---------------- LLM status values ------------------------------- */
    public static final String LLM_STATUS_SUCCESS  = 'success';
    public static final String LLM_STATUS_FALLBACK = 'fallback';

    /* ---------------- Dashboard stats output keys --------------------- */
    public static final String STAT_VISITS_THIS_WEEK   = 'visitsThisWeek';
    public static final String STAT_VISITS_THIS_MONTH  = 'visitsThisMonth';
    public static final String STAT_OPEN_TASKS         = 'openTasks';
    public static final String STAT_EXPENSE_THIS_MONTH = 'expenseThisMonth';

    /* ---------------- Save result keys -------------------------------- */
    public static final String RESULT_KEY_SUCCESS    = 'success';
    public static final String RESULT_KEY_VISIT_ID   = 'visitId';
    public static final String RESULT_KEY_VISIT_NAME = 'visitName';

    /* ============================================================== */
    /* WHATSAPP INTEGRATION                                           */
    /* ============================================================== */

    /* ---------------- WhatsApp Cloud API ------------------------------ */
    public static final String  WA_GRAPH_API_URL          = 'https://graph.facebook.com/v19.0/';
    public static final Integer WA_HTTP_TIMEOUT_MS        = 10000;
    public static final Integer WA_SESSION_TIMEOUT_MINUTES = 30;

    /* ---------------- WhatsApp Webhook verification ------------------- */
    public static final String WA_HUB_MODE_SUBSCRIBE = 'subscribe';
    public static final String WA_OPTIONS_OPEN_TAG   = '<OPTIONS>';
    public static final String WA_OPTIONS_CLOSE_TAG  = '</OPTIONS>';

    /* ---------------- WhatsApp session statuses ----------------------- */
    public static final String SESSION_STATUS_ACTIVE = 'Active';
    public static final String SESSION_STATUS_CLOSED = 'Closed';

    /* ---------------- WhatsApp message directions --------------------- */
    public static final String DIRECTION_INBOUND  = 'Inbound';
    public static final String DIRECTION_OUTBOUND = 'Outbound';

    /* ---------------- WhatsApp message types -------------------------- */
    public static final String MSG_TYPE_TEXT     = 'Text';
    public static final String MSG_TYPE_IMAGE    = 'Image';
    public static final String MSG_TYPE_AUDIO    = 'Audio';
    public static final String MSG_TYPE_VIDEO    = 'Video';
    public static final String MSG_TYPE_DOCUMENT = 'Document';

    public static final Set<String> MSG_TYPES_MEDIA = new Set<String>{
        MSG_TYPE_IMAGE, MSG_TYPE_AUDIO, MSG_TYPE_VIDEO, MSG_TYPE_DOCUMENT
    };

    /* ---------------- WhatsApp message statuses ----------------------- */
    public static final String MSG_STATUS_RECEIVED = 'Received';
    public static final String MSG_STATUS_SENT     = 'Sent';
    public static final String MSG_STATUS_FAILED   = 'Failed';

    /* ---------------- WhatsApp default user-facing replies ------------ */
    public static final String MSG_DEFAULT_DONE         = 'Done!';
    public static final String MSG_UNSUPPORTED_TYPE     = 'Oops! Something didn’t go as expected. Please try again.';
    public static final String MSG_AGENT_ERROR          = 'Sorry, something went wrong. Please try again.';
    public static final String MSG_SELECT_OPTION_PROMPT = '\nReply with the number.';
}