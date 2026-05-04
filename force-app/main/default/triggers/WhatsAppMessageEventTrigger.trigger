trigger WhatsAppMessageEventTrigger on WhatsApp_Message_Event__e (after insert) {
    system.debug('trigger start');
    for (WhatsApp_Message_Event__e eventRec : Trigger.New) {

        

        Id sessionId = (Id) eventRec.Session_Id__c;
        String fromNumber = eventRec.From_Number__c;
        String msgBody = eventRec.Message_Body__c;
        Id resolvedUserId = eventRec.Resolved_User_Id__c ;

        if (eventRec.Action__c == 'PROCESS_AGENT') {

            WhatsAppWebhookHandler.processAgentReplyAsync(
                sessionId, fromNumber, msgBody, resolvedUserId,eventRec.Message_Id__c
            );

        } else {
            WhatsAppWebhookHandler.sendUnsupportedTypeReplyAsync(
                sessionId, fromNumber, resolvedUserId
            );
        }
    }
}