import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import FIRST_NAME from '@salesforce/schema/User.FirstName';
import { getRecord, getFieldValue } from 'lightning/uiRecordApi';
import USER_ID from '@salesforce/user/Id';

import sendToAgent from '@salesforce/apex/PostVisitAgentInvoker.sendToAgent';

export default class AgentChatModal extends LightningElement {

    @api initialUtterance;
    @api persistedSessionId;
    @api agentName = 'Field Assistant';

    /**
     * Real agent activation status — queried in parent (visitLogger)
     * once per tab load via PostVisitAgentInvoker.isAgentActive Apex.
     * Stays fixed for the session — does NOT flip on call errors,
     * since an active agent can still produce errors mid-conversation.
     */
    @api isAgentActive = false;

    @track messages = [];
    @track inputText = '';
    @track isLoading = false;
    @track isListening = false;
    @track isFullScreen = false;

    sessionId = null;
    _userFirstName = 'You';
    _msgIdCounter = 0;
    _recognition = null;
    _hasSentInitial = false;
    _finalSpeechParts = [];

    // ═══════════════════════════════════════════════════════
    //  WIRES
    // ═══════════════════════════════════════════════════════

    @wire(getRecord, { recordId: USER_ID, fields: [FIRST_NAME] })
    wiredUser({ data }) {
        if (data) {
            this._userFirstName = getFieldValue(data, FIRST_NAME) || 'You';
        }
    }

    // ═══════════════════════════════════════════════════════
    //  GETTERS
    // ═══════════════════════════════════════════════════════

    get userName() {
        return this._userFirstName;
    }

    get isSendDisabled() {
        return this.isLoading || !this.inputText.trim();
    }

    get sheetClass() {
        return this.isFullScreen ? 'sheet sheet-fullscreen' : 'sheet';
    }

    get fullScreenTitle() {
        return this.isFullScreen ? 'Collapse' : 'Expand to full screen';
    }

    get statusClass() {
        return this.isAgentActive
            ? 'sheet-status status-active'
            : 'sheet-status status-inactive';
    }

    get statusLabel() {
        return this.isAgentActive ? 'Active' : 'Inactive';
    }

    // ═══════════════════════════════════════════════════════
    //  LIFECYCLE
    // ═══════════════════════════════════════════════════════

    connectedCallback() {
        if (this.persistedSessionId) {
            this.sessionId = this.persistedSessionId;
        }

        this._initSpeech();

        if (this.initialUtterance && !this._hasSentInitial) {
            this._hasSentInitial = true;
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => {
                this._sendMessage(this.initialUtterance);
            }, 250);
        }
    }

    disconnectedCallback() {
        this._cleanupSpeech();
    }

    renderedCallback() {
        this._scrollToBottom();
    }

    // ═══════════════════════════════════════════════════════
    //  FULL-SCREEN TOGGLE
    // ═══════════════════════════════════════════════════════

    handleToggleFullScreen() {
        this.isFullScreen = !this.isFullScreen;
    }

    // ═══════════════════════════════════════════════════════
    //  SPEECH RECOGNITION
    // ═══════════════════════════════════════════════════════

    _initSpeech() {
        const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!SR) {
            return;
        }

        this._recognition = new SR();
        this._recognition.continuous = false;
        this._recognition.interimResults = true;
        this._recognition.lang = 'en-IN';
        this._recognition.maxAlternatives = 1;

        this._recognition.onresult = (event) => {
            let interimText = '';
            for (let i = event.resultIndex; i < event.results.length; i++) {
                const chunk = event.results[i][0].transcript;
                if (event.results[i].isFinal) {
                    this._finalSpeechParts.push(chunk.trim());
                } else {
                    interimText = chunk;
                }
            }
            const finalText = this._finalSpeechParts.join(' ');
            this.inputText = (finalText + ' ' + interimText).trim();
        };

        this._recognition.onerror = (event) => {
            console.error('Speech error:', event.error);
            this.isListening = false;
        };

        this._recognition.onend = () => {
            this.isListening = false;
        };
    }

    _cleanupSpeech() {
        if (this._recognition && this.isListening) {
            try { this._recognition.stop(); } catch (e) { /* ignore */ }
        }
    }

    handleMicClick() {
        if (!this._recognition) {
            this._toast('Voice not available', 'Speech recognition not supported on this device.', 'warning');
            return;
        }

        if (this.isListening) {
            try { this._recognition.stop(); } catch (e) { /* ignore */ }
            return;
        }

        this.inputText = '';
        this._finalSpeechParts = [];
        this.isListening = true;
        try {
            this._recognition.start();
        } catch (e) {
            console.error('Recognition start failed:', e);
            this.isListening = false;
        }
    }

    // ═══════════════════════════════════════════════════════
    //  INPUT HANDLERS
    // ═══════════════════════════════════════════════════════

    handleInputChange(event) {
        this.inputText = event.target.value;
    }

    handleInputKeyUp(event) {
        if (event.key === 'Enter' && !this.isSendDisabled) {
            this.handleSend();
        }
    }

    handleSend() {
        const text = this.inputText.trim();
        if (!text) {
            return;
        }
        this.inputText = '';
        this._finalSpeechParts = [];
        this._sendMessage(text);
    }

    handleOptionSelected(event) {
        const reply = event.detail.reply;
        this._sendMessage(reply);
    }

    handleClose() {
        this.dispatchEvent(new CustomEvent('close', {
            detail: { sessionId: this.sessionId }
        }));
    }

    // ═══════════════════════════════════════════════════════
    //  MESSAGE FLOW
    //  Note: Status is NOT flipped on errors. The status reflects
    //  the agent's deployed state, not individual call success.
    // ═══════════════════════════════════════════════════════

    async _sendMessage(text) {
        this._addMessage({ role: 'user', text });
        const typingId = this._addMessage({ role: 'typing', text: '' });
        this.isLoading = true;

        try {
            const reply = await sendToAgent({
                userMessage: text,
                sessionId: this.sessionId
            });

            this._removeMessage(typingId);

            if (reply.success) {
                this.sessionId = reply.sessionId;
                this._addMessage({
                    role: 'agent',
                    text: reply.agentResponse || ''
                });

                this.dispatchEvent(new CustomEvent('sessionupdate', {
                    detail: { sessionId: this.sessionId }
                }));
            } else {
                this._addMessage({
                    role: 'agent',
                    text: '⚠️ ' + (reply.errorMessage || 'Agent error. Please try again.')
                });
            }
        } catch (error) {
            this._removeMessage(typingId);
            const msg = error?.body?.message || error?.message || 'Unknown error';
            this._addMessage({
                role: 'agent',
                text: '⚠️ ' + msg
            });
        } finally {
            this.isLoading = false;
        }
    }

    _addMessage(msg) {
        const id = 'msg-' + (++this._msgIdCounter);
        this.messages = [...this.messages, { id, ...msg }];
        return id;
    }

    _removeMessage(id) {
        this.messages = this.messages.filter(m => m.id !== id);
    }

    _scrollToBottom() {
        const container = this.refs?.msgsContainer;
        if (container) {
            container.scrollTop = container.scrollHeight;
        }
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}