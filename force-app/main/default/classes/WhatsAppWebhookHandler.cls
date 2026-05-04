/**
 * REST endpoint that receives WhatsApp webhook callbacks from Meta Cloud API.
 *
 * GET  - webhook verification handshake (called once by Meta during setup)
 * POST - inbound WhatsApp message events
 *
 * URL: /services/apexrest/whatsapp/webhook
 *      (exposed publicly via the "WhatsApp Webhook" Salesforce Site)
 *
 * Architecture:
 *  - doPost runs synchronously: dedup, get/create session, log inbound message, return 200 fast.
 *  - The agent invocation + outbound WhatsApp callout happen in @future(callout=true)
 *    to avoid the "uncommitted work pending" error when mixing DML and callouts.
 *
 *  - Phone-to-User resolution: matches inbound phone number against User.Whatsapp_Number__c.
 *    If matched, the User Id becomes the OwnerId on Whatsapp_Session__c and Whatsapp_Message__c
 *    records. The Get_Sales_Rep_User sub-flow reads this OwnerId via Agent_Session_ID__c lookup.
 */
@RestResource(urlMapping='/whatsapp/webhook/*')
global without sharing class WhatsAppWebhookHandler {

    @HttpGet
    global static void doGet() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        String mode      = req.params.get('hub.mode');
        String token     = req.params.get('hub.verify_token');
        String challenge = req.params.get('hub.challenge');

        Whatsapp_Configuration__mdt config = getConfig();

        if (config != null
                && GlobalConstants.WA_HUB_MODE_SUBSCRIBE.equals(mode)
                && config.Verify_Token__c.equals(token)) {
            res.statusCode   = 200;
            res.responseBody = Blob.valueOf(challenge);
        } else {
            res.statusCode = 403;
        }
    }

    @HttpPost
    global static void doPost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;

        try {
            String body = req.requestBody.toString();
            System.debug(LoggingLevel.DEBUG, 'WhatsApp Inbound Payload: ' + body);

            Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(body);
            List<Object> entries = (List<Object>) payload.get('entry');

            if (entries == null || entries.isEmpty()) {
                res.statusCode = 200;
                return;
            }

            for (Object entryObj : entries) {
                processEntry((Map<String, Object>) entryObj);
            }

            res.statusCode = 200;

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'WhatsAppWebhookHandler error: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            res.statusCode = 200;
        }
    }

    private static void processEntry(Map<String, Object> entry) {
        List<Object> changes = (List<Object>) entry.get('changes');
        if (changes == null) {
            return;
        }

        for (Object changeObj : changes) {
            Map<String, Object> change = (Map<String, Object>) changeObj;
            Map<String, Object> value  = (Map<String, Object>) change.get('value');
            if (value == null) {
                continue;
            }

            String profileName = extractProfileName(value);

            List<Object> messages = (List<Object>) value.get('messages');
            if (messages == null) {
                continue;
            }

            for (Object msgObj : messages) {
                processMessage((Map<String, Object>) msgObj, profileName);
            }
        }
    }

    private static String extractProfileName(Map<String, Object> value) {
        List<Object> contacts = (List<Object>) value.get('contacts');
        if (contacts == null || contacts.isEmpty()) {
            return null;
        }
        Map<String, Object> contact = (Map<String, Object>) contacts[0];
        Map<String, Object> profile = (Map<String, Object>) contact.get('profile');
        if (profile == null) {
            return null;
        }
        return (String) profile.get('name');
    }

    private static void processMessage(Map<String, Object> msg, String profileName) {
        String fromNumber = (String) msg.get('from');
        String rawType    = (String) msg.get('type');
        String waMsgId    = (String) msg.get('id');

        if (String.isBlank(fromNumber) || String.isBlank(rawType)) {
            return;
        }

        if (isDuplicate(waMsgId)) {
            System.debug(LoggingLevel.INFO, 'Duplicate WhatsApp message ignored: ' + waMsgId);
            return;
        }

        String msgType  = normaliseMessageType(rawType);
        String msgBody  = extractMessageBody(msg, rawType);
        String mediaUrl = extractMediaUrl(msg, rawType);
        String action;

        // Resolve the sales-rep User from the inbound phone number.
        Id resolvedUserId = resolveUserIdFromPhone(fromNumber);

        // 1. Get/create session (DML) — sets OwnerId if rep was resolved
        Whatsapp_Session__c session = getOrCreateSession(fromNumber, profileName, resolvedUserId);

        // 2. Log inbound message (DML) — status = Received, OwnerId = rep (if resolved)
        Whatsapp_Message__c m = logMessage(session.Id, GlobalConstants.DIRECTION_INBOUND, msgType,
                   msgBody, waMsgId, mediaUrl,
                   GlobalConstants.MSG_STATUS_RECEIVED, null, resolvedUserId);

        // NEW: Handle media (image/pdf/document)
        if (mediaUrl != null) {
            handleMediaAsync(session.Id, mediaUrl, rawType, waMsgId, m.id, fromNumber,msgBody, resolvedUserId);
        }
        else{
                    // 3. Only route text messages to the agent.
        //    Hand off to async method so DML and callouts don't clash.
        if (GlobalConstants.MSG_TYPE_TEXT.equals(msgType) && String.isNotBlank(msgBody)) {
            processAgentReplyAsync(session.Id, fromNumber, msgBody, resolvedUserId,m.id);
        } else {
            sendUnsupportedTypeReplyAsync(session.Id, fromNumber, resolvedUserId);
        }
        }
        
        
    }

    /* --------------------------------------------------------------- */
    /* Phone-to-User resolution                                        */
    /* --------------------------------------------------------------- */

    /**
     * Matches the inbound WhatsApp phone number against User.Whatsapp_Number__c.
     * Both formats (with/without '+') are normalized to digits-only and matched
     * by last-10-digit suffix to be country-code agnostic.
     *
     * Returns the User Id if exactly one active match, otherwise null.
     */
    private static Id resolveUserIdFromPhone(String phoneNumber) {
        if (String.isBlank(phoneNumber)) {
            return null;
        }

        String normalized = normalizePhoneToLast10(phoneNumber);
        if (String.isBlank(normalized)) {
            return null;
        }

        // Suffix match — '%9876543210' covers '+919876543210', '919876543210', '9876543210'
        String suffixPattern = '%' + normalized;

        List<User> users = [
            SELECT Id
            FROM User
            WHERE IsActive = true
              AND Whatsapp_Number__c LIKE :suffixPattern
            WITH SYSTEM_MODE
            LIMIT 2
        ];

        if (users.size() == 1) {
            return users[0].Id;
        }

        if (users.size() > 1) {
            System.debug(LoggingLevel.WARN,
                'Multiple users matched WhatsApp number suffix: ' + normalized
                + ' — falling back to default owner.');
        }

        return null;
    }

    /**
     * Strips all non-digit characters and returns the last 10 digits.
     * Returns null/blank for inputs with fewer than 4 digits.
     */
    @TestVisible
    private static String normalizePhoneToLast10(String phoneNumber) {
        if (String.isBlank(phoneNumber)) {
            return null;
        }
        String digitsOnly = phoneNumber.replaceAll('[^0-9]', '');
        if (digitsOnly.length() < 4) {
            return null;
        }
        if (digitsOnly.length() > 10) {
            return digitsOnly.substring(digitsOnly.length() - 10);
        }
        return digitsOnly;
    }

    /* --------------------------------------------------------------- */
    /* Async — Agent invocation + outbound WhatsApp reply              */
    /* --------------------------------------------------------------- */

    @future(callout=true)
    public static void processAgentReplyAsync(Id sessionId, String fromNumber, String msgBody, Id resolvedUserId, id messageRecId) {
        
        try {
            List<Whatsapp_Session__c> sessions = [
                SELECT Id, Agent_Session_ID__c
                FROM Whatsapp_Session__c
                WHERE Id = :sessionId
                WITH SYSTEM_MODE
                LIMIT 1
            ];
            if (sessions.isEmpty()) {
                return;
            }
            Whatsapp_Session__c session = sessions[0];

            // CALLOUT 1: Invoke Agentforce (Service Agent)
            WhatsAppService.AgentReply reply =
                WhatsAppService.sendToAgent(msgBody, session.Agent_Session_ID__c,messageRecId );

            String responseText;
            String newAgentSessionId = session.Agent_Session_ID__c;

            if (reply.success) {
                newAgentSessionId = reply.sessionId;
                responseText = formatAgentResponse(reply.agentResponse);
            } else {
                System.debug(LoggingLevel.ERROR, 'Agent error: ' + reply.errorMessage);
                responseText = GlobalConstants.MSG_AGENT_ERROR;
            }

            // CALLOUT 2: Send WhatsApp reply (returns Meta's outbound message id)
            String outboundWaMsgId = WhatsAppService.sendTextMessage(fromNumber, responseText);

            // DML AFTER all callouts are done
            session.Agent_Session_ID__c = newAgentSessionId;
            session.Last_Activity__c   = DateTime.now();
            update session; // NOPMD

            logMessage(sessionId, GlobalConstants.DIRECTION_OUTBOUND,
                       GlobalConstants.MSG_TYPE_TEXT, responseText,
                       outboundWaMsgId, null, GlobalConstants.MSG_STATUS_SENT, null,
                       resolvedUserId);

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'processAgentReplyAsync error: ' + e.getMessage()
                + '\n' + e.getStackTraceString());
            // Best effort: log a failed outbound entry
            logMessage(sessionId, GlobalConstants.DIRECTION_OUTBOUND,
                       GlobalConstants.MSG_TYPE_TEXT, null, null, null,
                       GlobalConstants.MSG_STATUS_FAILED, e.getMessage(),
                       resolvedUserId);
        }
    }

    @future(callout=true)
    public static void sendUnsupportedTypeReplyAsync(Id sessionId, String fromNumber, Id resolvedUserId) {
        try {
            String body = GlobalConstants.MSG_UNSUPPORTED_TYPE;
            String outboundWaMsgId = WhatsAppService.sendTextMessage(fromNumber, body);

            logMessage(sessionId, GlobalConstants.DIRECTION_OUTBOUND,
                       GlobalConstants.MSG_TYPE_TEXT, body, outboundWaMsgId,
                       null, GlobalConstants.MSG_STATUS_SENT, null,
                       resolvedUserId);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR,
                'sendUnsupportedTypeReplyAsync error: ' + e.getMessage());
        }
    }

    /* --------------------------------------------------------------- */
    /* Session helpers                                                 */
    /* --------------------------------------------------------------- */

    private static Whatsapp_Session__c getOrCreateSession(String phoneNumber, String profileName, Id resolvedUserId) {
        List<Whatsapp_Session__c> sessions = [
            SELECT Id, Agent_Session_ID__c, Last_Activity__c, Status__c, OwnerId
            FROM Whatsapp_Session__c
            WHERE Phone_Number__c = :phoneNumber
            AND Status__c = :GlobalConstants.SESSION_STATUS_ACTIVE
            WITH SYSTEM_MODE
            ORDER BY Last_Activity__c DESC
            LIMIT 1
        ];

        if (!sessions.isEmpty()) {
            Whatsapp_Session__c existing = sessions[0];
            Long diffMinutes = (DateTime.now().getTime() - existing.Last_Activity__c.getTime()) / 60000;

            if (diffMinutes <= GlobalConstants.WA_SESSION_TIMEOUT_MINUTES) {
                // Session reused — keep OwnerId in sync if rep was resolved
                // and existing OwnerId differs.
                if (resolvedUserId != null && existing.OwnerId != resolvedUserId) {
                    existing.OwnerId = resolvedUserId;
                    update existing; // NOPMD
                }
                return existing;
            }

            existing.Status__c = GlobalConstants.SESSION_STATUS_CLOSED;
            update existing; // NOPMD
        }

        Whatsapp_Session__c newSession = new Whatsapp_Session__c(
            Phone_Number__c   = phoneNumber,
            Profile_Name__c   = profileName,
            Status__c         = GlobalConstants.SESSION_STATUS_ACTIVE,
            Last_Activity__c  = DateTime.now()
        );
        if (resolvedUserId != null) {
            newSession.OwnerId = resolvedUserId;
        }
        insert newSession; // NOPMD
        return newSession;
    }

    /* --------------------------------------------------------------- */
    /* Message helpers                                                 */
    /* --------------------------------------------------------------- */

    private static Boolean isDuplicate(String waMsgId) {
        if (String.isBlank(waMsgId)) {
            return false;
        }
        Integer cnt = [
            SELECT COUNT()
            FROM Whatsapp_Message__c
            WHERE WhatsApp_Message_ID__c = :waMsgId
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        return cnt > 0;
    }

    private static String normaliseMessageType(String rawType) {
        if (String.isBlank(rawType)) {
            return null;
        }
        return rawType.substring(0, 1).toUpperCase() + rawType.substring(1).toLowerCase();
    }

    
    private static String extractMessageBody(Map<String, Object> msg, String rawType) {

        // 1. TEXT messages (existing logic)
        if ('text'.equalsIgnoreCase(rawType)) {
            Map<String, Object> textMap = (Map<String, Object>) msg.get('text');
            return textMap == null ? null : (String) textMap.get('body');
        }
    
        // 2. INTERACTIVE messages (existing logic)
        if ('interactive'.equalsIgnoreCase(rawType)) {
            Map<String, Object> interactive = (Map<String, Object>) msg.get('interactive');
            if (interactive == null) {
                return null;
            }
            Map<String, Object> buttonReply = (Map<String, Object>) interactive.get('button_reply');
            if (buttonReply != null) {
                return (String) buttonReply.get('title');
            }
            Map<String, Object> listReply = (Map<String, Object>) interactive.get('list_reply');
            if (listReply != null) {
                return (String) listReply.get('title');
            }
        }
    
        // 3. NEW: MEDIA messages (image, document, video, etc.)
        if (GlobalConstants.MSG_TYPES_MEDIA.contains(normaliseMessageType(rawType))) {
            Map<String, Object> mediaMap = (Map<String, Object>) msg.get(rawType);
            if (mediaMap != null && mediaMap.containsKey('caption')) {
                return (String) mediaMap.get('caption');
            }
        }
    
        return null;
}
    
    private static String extractMediaUrl(Map<String, Object> msg, String rawType) {
        if (!GlobalConstants.MSG_TYPES_MEDIA.contains(normaliseMessageType(rawType))) {
            return null;
        }
        Map<String, Object> mediaMap = (Map<String, Object>) msg.get(rawType);
        if (mediaMap == null) {
            return null;
        }
        return (String) mediaMap.get('id');
    }

    public static Whatsapp_Message__c logMessage(
        Id sessionId,
        String direction,
        String msgType,
        String body,
        String waMsgId,
        String mediaUrl,
        String status,
        String errorMessage,
        Id resolvedUserId
    ) {
        Whatsapp_Message__c m;
        try {
            m = new Whatsapp_Message__c(
                WhatsApp_Session__c    = sessionId,
                Direction__c           = direction,
                Message_Type__c        = msgType,
                Message_Body__c        = body,
                WhatsApp_Message_ID__c = waMsgId,
                Media_URL__c           = mediaUrl,
                Status__c              = status,
                Error_Message__c       = errorMessage
            );
            if (resolvedUserId != null) {
                m.OwnerId = resolvedUserId;
            }
            insert m; // NOPMD

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'logMessage error: ' + e.getMessage());
        }
        return m;
    }

    /* --------------------------------------------------------------- */
    /* Agent response formatting                                       */
    /* --------------------------------------------------------------- */

    private static String formatAgentResponse(String agentResponse) {
        if (String.isBlank(agentResponse)) {
            return GlobalConstants.MSG_DEFAULT_DONE;
        }

        // Service Agent returns JSON like {"type":"Text","value":"..."}
        // Unwrap to get just the user-facing value.
        String unwrapped = WhatsAppService.unwrapAgentResponse(agentResponse);

        if (!unwrapped.contains(GlobalConstants.WA_OPTIONS_OPEN_TAG)) {
            return unwrapped;
        }

        try {
            Integer tagStart  = unwrapped.indexOf(GlobalConstants.WA_OPTIONS_OPEN_TAG);
            Integer tagEnd    = unwrapped.indexOf(GlobalConstants.WA_OPTIONS_CLOSE_TAG);
            String prefix     = unwrapped.substring(0, tagStart).trim();
            Integer bodyStart = tagStart + GlobalConstants.WA_OPTIONS_OPEN_TAG.length();
            String optionsJson = unwrapped.substring(bodyStart, tagEnd).trim();

            List<Object> options = (List<Object>) JSON.deserializeUntyped(optionsJson);

            String formatted = String.isNotBlank(prefix) ? prefix + '\n\n' : '';
            for (Integer i = 0; i < options.size(); i++) {
                formatted += (i + 1) + '. ' + (String) options[i] + '\n';
            }
            formatted += GlobalConstants.MSG_SELECT_OPTION_PROMPT;
            return formatted.trim();

        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'OPTIONS parse error: ' + e.getMessage());
            return unwrapped;
        }
    }

    /* --------------------------------------------------------------- */
    /* Config                                                          */
    /* --------------------------------------------------------------- */

    private static Whatsapp_Configuration__mdt getConfig() {
        List<Whatsapp_Configuration__mdt> configs = [
            SELECT Access_Token__c, Phone_Number_ID__c,
                   Business_Account_ID__c, Verify_Token__c
            FROM Whatsapp_Configuration__mdt
            LIMIT 1
        ];
        return configs.isEmpty() ? null : configs[0];
    }

    @future(callout=true)
    public static void handleMediaAsync(Id sessionId, String mediaId, String rawType, String waMsgId, string mid, String fromNumber, String msgBody, Id resolvedUserId) {
        try {
            // Step 1: Get WhatsApp config
            Whatsapp_Configuration__mdt config = getConfig();
            if (config == null || String.isBlank(config.Access_Token__c)) {
                System.debug('Missing WhatsApp config');
                return;
            }

            Http http = new Http();

            // Step 2: Get media metadata (to get download URL)
            HttpRequest metaReq = new HttpRequest();
            metaReq.setEndpoint('https://graph.facebook.com/v19.0/' + mediaId);
            metaReq.setMethod('GET');
            metaReq.setHeader('Authorization', 'Bearer ' + config.Access_Token__c);

            HttpResponse metaRes = http.send(metaReq);

            if (metaRes.getStatusCode() != 200) {
                System.debug('Failed to get media URL: ' + metaRes.getBody());
                return;
            }

            Map<String, Object> metaMap =
                (Map<String, Object>) JSON.deserializeUntyped(metaRes.getBody());

            String downloadUrl = (String) metaMap.get('url');
            String mimeType    = (String) metaMap.get('mime_type');

            // Step 3: Download actual file
            HttpRequest fileReq = new HttpRequest();
            fileReq.setEndpoint(downloadUrl);
            fileReq.setMethod('GET');
            fileReq.setHeader('Authorization', 'Bearer ' + config.Access_Token__c);

            HttpResponse fileRes = http.send(fileReq);

            if (fileRes.getStatusCode() != 200) {
                System.debug('Failed to download file');
                return;
            }

            Blob fileBlob = fileRes.getBodyAsBlob();

            // Step 4: Create File in Salesforce
            ContentVersion cv = new ContentVersion();
            cv.Title = 'WhatsApp_' + rawType + '_' + Datetime.now().getTime();
            cv.PathOnClient = 'WhatsApp_' + rawType + '.' + getExtension(mimeType);
            cv.VersionData = fileBlob;

            // IMPORTANT FIX
            cv.FirstPublishLocationId = mid;

            insert cv;
            
            // Get ContentDocumentId
            Id contentDocId = [
                SELECT ContentDocumentId 
                FROM ContentVersion 
                WHERE Id = :cv.Id
            ].ContentDocumentId;
            
            // Re-fetch message to decide action
            Whatsapp_Message__c msg = [
                SELECT Message_Type__c, Message_Body__c, OwnerId
                FROM Whatsapp_Message__c
                WHERE Id = :mid
                LIMIT 1
            ];
            
            String action;
            
            if ((msg.Message_Type__c == 'Text'
                || msg.Message_Type__c == 'Image'
                || msg.Message_Type__c == 'Document')
                && String.isNotBlank(msg.Message_Body__c)) {
            
                action = 'PROCESS_AGENT';
            } else {
                action = 'UNSUPPORTED';
            }
            
            // Publish event AFTER media is ready
            WhatsApp_Message_Event__e eventMsg = new WhatsApp_Message_Event__e(
                Session_Id__c = sessionId,
                Message_Id__c = mid,
                Resolved_User_Id__c = resolvedUserId,
                Action__c = action,
                From_Number__c  = fromNumber,
                Message_Body__c = msgBody,
                Message_Type__c  = rawType
            );
            
            EventBus.publish(eventMsg);
            Database.SaveResult sr = EventBus.publish(eventMsg);
            System.debug('Event Publish Status: ' + sr.isSuccess());
            
            if (!sr.isSuccess()) {
                System.debug('Event Error: ' + sr.getErrors()[0].getMessage());
            }
                        
            //  CALL FLOW WITH FILE
            //invokeFlowWithFile(contentDocId, mid);


            System.debug('File saved successfully');

        } catch (Exception e) {
            System.debug('handleMediaAsync error: ' + e.getMessage());
        }
    }

    private static String getExtension(String mimeType) {
        if (mimeType == null) return 'dat';
        if (mimeType.contains('pdf')) return 'pdf';
        if (mimeType.contains('jpeg')) return 'jpg';
        if (mimeType.contains('png')) return 'png';
        if (mimeType.contains('image')) return 'jpg';
        if (mimeType.contains('video')) return 'mp4';
        return 'dat';
    }
    
    public static void invokeFlowWithFile(Id contentDocumentId, Id messageId) {
    try {
        Map<String, Object> inputs = new Map<String, Object>();
        inputs.put('contentDocumentId', contentDocumentId);
        inputs.put('messageId', messageId);

        Flow.Interview.Create_Expense_Service_Agent flow =
            new Flow.Interview.Create_Expense_Service_Agent(inputs);

        flow.start();

    } catch (Exception e) {
        System.debug('Flow invocation error: ' + e.getMessage());
    }
}

}