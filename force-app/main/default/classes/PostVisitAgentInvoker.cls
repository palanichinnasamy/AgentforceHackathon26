/**
 * PostVisitAgentInvoker
 * Invokes the OncoGlobally_Sales_AI_Employee_Agent Agentforce Employee Agent from LWC
 * and exposes the agent's active/inactive status.
 *
 * Uses the standard 'generateAiAgentResponse' invocable action.
 * Pass null sessionId on first turn, returned sessionId on subsequent turns
 * to maintain conversational context.
 */
public with sharing class PostVisitAgentInvoker {

    private static final String AGENT_API_NAME = 'OncoGlobally_Sales_AI_Employee_Agent';
    private static final String INVOCABLE_ACTION_NAME = 'generateAiAgentResponse';
    private static final String BOT_VERSION_STATUS_ACTIVE = 'Active';

    public class AgentReply {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String sessionId;
        @AuraEnabled public String agentResponse;
        @AuraEnabled public String errorMessage;
    }

    /**
     * Send a message to the agent.
     */
    @AuraEnabled
    public static AgentReply sendToAgent(String userMessage, String sessionId) {
        AgentReply reply = new AgentReply();

        if (String.isBlank(userMessage)) {
            reply.success = false;
            reply.errorMessage = 'User message is required.';
            return reply;
        }

        try {
            Invocable.Action action = Invocable.Action.createCustomAction(
                INVOCABLE_ACTION_NAME,
                AGENT_API_NAME
            );
            action.setInvocationParameter('userMessage', userMessage);

            if (String.isNotBlank(sessionId)) {
                action.setInvocationParameter('sessionId', sessionId);
            }

            List<Invocable.Action.Result> results = action.invoke();

            if (results == null || results.isEmpty()) {
                reply.success = false;
                reply.errorMessage = 'Agent returned no results.';
                return reply;
            }

            Invocable.Action.Result result = results[0];

            if (result.isSuccess()) {
                Map<String, Object> outputs = result.getOutputParameters();
                reply.success = true;
                reply.sessionId = (String) outputs.get('sessionId');
                reply.agentResponse = (String) outputs.get('agentResponse');
            } else {
                reply.success = false;
                reply.errorMessage = String.valueOf(result.getErrors());
            }
        } catch (Exception e) {
            reply.success = false;
            reply.errorMessage = e.getMessage();
            System.debug('PostVisitAgentInvoker error: ' + e.getMessage() + '\n' + e.getStackTraceString());
        }

        return reply;
    }

    /**
     * Returns true if the OncoGlobally_Sales_AI_Employee_Agent has at least
     * one BotVersion in 'Active' status.
     *
     * Two-step query because BotVersion's parent BotDefinition relationship
     * is not directly traversable in WHERE clauses:
     *  1. Find the BotDefinition Id by DeveloperName.
     *  2. Find any active BotVersion for that BotDefinition Id.
     *
     * @AuraEnabled(cacheable=true) — Salesforce caches result client-side
     * for the user's session. No re-query unless cache invalidated.
     */
    @AuraEnabled(cacheable=true)
    public static Boolean isAgentActive() {
        try {
            List<BotDefinition> definitions = [
                SELECT Id
                FROM BotDefinition
                WHERE DeveloperName = :AGENT_API_NAME
                LIMIT 1
            ];
            if (definitions.isEmpty()) {
                return false;
            }
            Id botDefId = definitions[0].Id;

            List<BotVersion> versions = [
                SELECT Id
                FROM BotVersion
                WHERE BotDefinitionId = :botDefId
                  AND Status = :BOT_VERSION_STATUS_ACTIVE
                LIMIT 1
            ];
            return !versions.isEmpty();
        } catch (Exception e) {
            // Object inaccessible, agent missing, etc. — treat as inactive.
            System.debug('isAgentActive query failed: ' + e.getMessage());
            return false;
        }
    }
}