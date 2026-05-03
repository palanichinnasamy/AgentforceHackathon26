/**
 * Service class for the WhatsApp integration.
 *
 * Responsibilities:
 *   1. Send outbound WhatsApp messages via Meta Cloud API.
 *   2. Invoke the WhatsApp-specific Agentforce Service Agent
 *      (GlobalConstants.SERVICE_AGENT_API_NAME) and parse its response.
 *
 * Auth: Bearer token read from Whatsapp_Configuration__mdt.Access_Token__c.
 *
 * Note: This class is PURE — it does NOT perform any DML.
 * The caller is responsible for logging messages / updating session state
 * after the callout completes. This separation is required to avoid the
 * "uncommitted work pending" error when mixing DML and callouts.
 */
public without sharing class WhatsAppService {

    public class WhatsAppException extends Exception {}

    public class AgentReply {
        @AuraEnabled public String  sessionId;
        @AuraEnabled public String  agentResponse;
        @AuraEnabled public Boolean success;
        @AuraEnabled public String  errorMessage;
    }

    /* --------------------------------------------------------------- */
    /* Agentforce                                                      */
    /* --------------------------------------------------------------- */

    /**
     * Invokes the Service Agent via the 'generateAiAgentResponse' invocable action.
     *
     * @param userMessage  The user's utterance.
     * @param sessionId    The Agent session id from a previous turn (or null
     *                     to start a new session).
     */
    public static AgentReply sendToAgent(String userMessage, String sessionId) {
        AgentReply reply = new AgentReply();
        reply.success = false;

        if (String.isBlank(userMessage)) {
            reply.errorMessage = 'userMessage is required.';
            return reply;
        }

        try {
            Invocable.Action action = Invocable.Action.createCustomAction(
                GlobalConstants.INVOCABLE_ACTION_NAME,
                GlobalConstants.SERVICE_AGENT_API_NAME
            );
            action.setInvocationParameter(GlobalConstants.AGENT_PARAM_USER_MSG, userMessage);

            if (String.isNotBlank(sessionId)) {
                action.setInvocationParameter(GlobalConstants.AGENT_PARAM_SESSION, sessionId);
            }

            List<Invocable.Action.Result> results = action.invoke();
            if (results.isEmpty()) {
                reply.errorMessage = 'No result returned from agent action.';
                return reply;
            }

            Invocable.Action.Result result = results[0];
            if (result.isSuccess()) {
                reply.success       = true;
                reply.sessionId     = (String) result.getOutputParameters().get(GlobalConstants.AGENT_PARAM_SESSION);
                reply.agentResponse = (String) result.getOutputParameters().get(GlobalConstants.AGENT_PARAM_RESPONSE);
            } else {
                reply.errorMessage = String.valueOf(result.getErrors());
            }
        } catch (Exception e) {
            reply.errorMessage = e.getMessage();
        }

        return reply;
    }

    /**
     * Service Agents return JSON like {"type":"Text","value":"actual message"}.
     * Extracts just the user-facing value.
     * Falls back to the raw input for non-JSON / Employee-Agent style responses.
     */
    public static String unwrapAgentResponse(String raw) {
        if (String.isBlank(raw) || !raw.trim().startsWith('{')) {
            return raw;
        }
        try {
            Object parsed = JSON.deserializeUntyped(raw);
            if (parsed instanceof Map<String, Object>) {
                Map<String, Object> m = (Map<String, Object>) parsed;
                Object value = m.get(GlobalConstants.AGENT_RESP_VALUE_KEY);
                if (value instanceof String) {
                    return (String) value;
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN,
                'unwrapAgentResponse parse failed: ' + e.getMessage());
        }
        return raw;
    }

    /* --------------------------------------------------------------- */
    /* WhatsApp Cloud API                                              */
    /* --------------------------------------------------------------- */

    /**
     * Sends a plain text WhatsApp message.
     * Returns the Meta-assigned message id (for correlation), or null if absent.
     * Throws WhatsAppException on HTTP/API errors so the caller can decide
     * how to log them.
     */
    public static String sendTextMessage(String toNumber, String messageBody) {
        if (String.isBlank(toNumber) || String.isBlank(messageBody)) {
            throw new WhatsAppException('toNumber and messageBody are required.');
        }

        Whatsapp_Configuration__mdt config = getConfig();

        Map<String, Object> payload = new Map<String, Object>{
            'messaging_product' => 'whatsapp',
            'to'                => toNumber,
            'type'              => 'text',
            'text'              => new Map<String, Object>{ 'body' => messageBody }
        };

        HttpRequest req = new HttpRequest();
        req.setEndpoint(GlobalConstants.WA_GRAPH_API_URL
                        + config.Phone_Number_ID__c + '/messages');
        req.setMethod('POST');
        req.setHeader('Authorization', 'Bearer ' + config.Access_Token__c);
        req.setHeader('Content-Type', 'application/json');
        req.setBody(JSON.serialize(payload));
        req.setTimeout(GlobalConstants.WA_HTTP_TIMEOUT_MS);

        Http http = new Http();
        HttpResponse res = http.send(req);

        Integer statusCode = res.getStatusCode();
        if (statusCode != 200 && statusCode != 201) {
            throw new WhatsAppException(
                'WhatsApp API Error: ' + statusCode + ' ' + res.getBody()
            );
        }

        return parseMessageId(res.getBody());
    }

    /* --------------------------------------------------------------- */
    /* Helpers                                                         */
    /* --------------------------------------------------------------- */

    private static String parseMessageId(String responseBody) {
        if (String.isBlank(responseBody)) {
            return null;
        }
        try {
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(responseBody);
            List<Object> messages = (List<Object>) parsed.get('messages');
            if (messages == null || messages.isEmpty()) {
                return null;
            }
            Map<String, Object> firstMsg = (Map<String, Object>) messages[0];
            return (String) firstMsg.get('id');
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'parseMessageId error: ' + e.getMessage());
            return null;
        }
    }

    private static Whatsapp_Configuration__mdt getConfig() {
        List<Whatsapp_Configuration__mdt> configs = [
            SELECT Access_Token__c, Phone_Number_ID__c,
                   Business_Account_ID__c, Verify_Token__c
            FROM Whatsapp_Configuration__mdt
            LIMIT 1
        ];
        if (configs.isEmpty()) {
            throw new WhatsAppException('Whatsapp_Configuration__mdt record not found.');
        }
        return configs[0];
    }
}