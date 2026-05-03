import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import Id from '@salesforce/user/Id';

import processTranscript from '@salesforce/apex/VisitLoggerController.processTranscript';
import isAgentActive from '@salesforce/apex/PostVisitAgentInvoker.isAgentActive';

const STATE = {
    DEFAULT: 'default',
    RECORDING: 'recording',
    REVIEW: 'review'
};

export default class VisitLoggerWithExpense extends NavigationMixin(LightningElement) {

    componentState = STATE.DEFAULT;
    isSaving = false;
    speechNotSupported = false;
    currentUserId = Id;

    transcript = '';
    recognition = null;
    timerInterval = null;
    elapsedSeconds = 0;
    _finalTranscriptParts = [];

    aiSummary = '';
    suggestions = [];
    uploadedFiles = [];
    isLoadingSummary = true;
    isLoadingSuggestions = true;

    _doctorName = '';
    _facilityName = '';
    _visitDate = '';
    _visitCardDescription = '';
    _visitUtterance = '';
    _taskSubject = '';
    _taskDueDate = '';
    _taskCardDescription = '';
    _taskUtterance = '';
    _expenseType = '';
    _expenseAmount = '';
    _expenseDescription = '';
    _expenseCardDescription = '';
    _expenseUtterance = '';

    isModalOpen = false;
    pendingUtterance = '';
    agentSessionId = null;

    showExpenseModal = false;

    // Cached agent active status — queried once on tab load,
    // passed into the modal as @api prop.
    isAgentActive = false;

    // ═══════════════════════════════════════════════════════
    //  GETTERS
    // ═══════════════════════════════════════════════════════

    get isDefaultState() { return this.componentState === STATE.DEFAULT; }
    get isRecording() { return this.componentState === STATE.RECORDING; }
    get isReviewState() { return this.componentState === STATE.REVIEW; }
    get hasSuggestions() { return this.suggestions && this.suggestions.length > 0; }
    get showBottomActions() { return !this.isModalOpen; }

    get transcriptOrEmpty() {
        return this.transcript || '(no speech detected)';
    }

    get aiSummaryOrEmpty() {
        return this.aiSummary || '(nothing to summarize)';
    }

    get formattedTime() {
        const m = Math.floor(this.elapsedSeconds / 60);
        const s = this.elapsedSeconds % 60;
        return `${m}:${s.toString().padStart(2, '0')}`;
    }

    // ═══════════════════════════════════════════════════════
    //  PUBLIC API
    // ═══════════════════════════════════════════════════════

    @api
    resetAndStart() {
        this._endSession();
        this._cleanupRecording();
        this._resetState();
        this._setState(STATE.DEFAULT);
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.startRecording();
        }, 100);
    }

    @api
    resetToDefault() {
        this._endSession();
        this._cleanupRecording();
        this._resetState();
        this._setState(STATE.DEFAULT);
    }

    // ═══════════════════════════════════════════════════════
    //  LIFECYCLE
    // ═══════════════════════════════════════════════════════

    connectedCallback() {
        this._initSpeech();
        this._loadAgentStatus();
    }

    disconnectedCallback() {
        this._cleanupRecording();
    }

    // ═══════════════════════════════════════════════════════
    //  AGENT STATUS
    // ═══════════════════════════════════════════════════════

    async _loadAgentStatus() {
        try {
            this.isAgentActive = await isAgentActive();
        } catch (e) {
            console.error('Failed to load agent status:', e);
            this.isAgentActive = false;
        }
    }

    // ═══════════════════════════════════════════════════════
    //  SPEECH RECOGNITION
    // ═══════════════════════════════════════════════════════

    _initSpeech() {
        const SR = window.SpeechRecognition || window.webkitSpeechRecognition;
        if (!SR) {
            this.speechNotSupported = true;
            return;
        }

        this.recognition = new SR();
        this.recognition.continuous = false;
        this.recognition.interimResults = true;
        this.recognition.lang = 'en-IN';

        this.recognition.onresult = (event) => {
            let interimText = '';
            for (let i = event.resultIndex; i < event.results.length; i++) {
                const chunk = event.results[i][0].transcript;
                if (event.results[i].isFinal) {
                    this._finalTranscriptParts.push(chunk.trim());
                } else {
                    interimText = chunk;
                }
            }
            const finalText = this._finalTranscriptParts.join(' ');
            this.transcript = (finalText + ' ' + interimText).trim();
        };

        this.recognition.onerror = (event) => {
            console.error('Speech error:', event.error);
            if (event.error === 'not-allowed' || event.error === 'service-not-available') {
                this.speechNotSupported = true;
                this._setState(STATE.DEFAULT);
                this._cleanupRecording();
                this._toast('Microphone', 'Allow mic access in browser settings.', 'warning');
            }
        };

        this.recognition.onend = () => {
            if (this.componentState === STATE.RECORDING) {
                try { this.recognition.start(); } catch (e) { /* already running */ }
            }
        };
    }

    // ═══════════════════════════════════════════════════════
    //  RECORDING CONTROLS
    // ═══════════════════════════════════════════════════════

    startRecording() {
        if (this.speechNotSupported) {
            this.transcript = '';
            this._setState(STATE.REVIEW);
            this._processVisitTranscript();
            return;
        }

        if (!this.recognition) {
            this._initSpeech();
            if (!this.recognition) {
                return;
            }
        }

        this.transcript = '';
        this._finalTranscriptParts = [];
        this.elapsedSeconds = 0;
        this._setState(STATE.RECORDING);

        try {
            this.recognition.start();
        } catch (e) {
            console.error('Recognition start failed:', e);
        }

        // eslint-disable-next-line @lwc/lwc/no-async-operation
        this.timerInterval = setInterval(() => {
            this.elapsedSeconds++;
        }, 1000);
    }

    stopRecording() {
        this._cleanupRecording();
        this._setState(STATE.REVIEW);
        this._processVisitTranscript();
    }

    _cleanupRecording() {
        if (this.recognition) {
            try { this.recognition.stop(); } catch (e) { /* not started */ }
        }
        if (this.timerInterval) {
            clearInterval(this.timerInterval);
            this.timerInterval = null;
        }
    }

    // ═══════════════════════════════════════════════════════
    //  PROCESS TRANSCRIPT
    // ═══════════════════════════════════════════════════════

    async _processVisitTranscript() {
        const text = this.transcript || '';

        this.isLoadingSummary = true;
        this.isLoadingSuggestions = true;
        this.aiSummary = '';
        this.suggestions = [];
        this._resetExtractedEntities();

        if (!text.trim()) {
            this.aiSummary = '';
            this.isLoadingSummary = false;
            this.isLoadingSuggestions = false;
            return;
        }

        try {
            const result = await processTranscript({ rawTranscript: text });
            this.aiSummary = result.summary || text;

            this._doctorName = result.doctorName || '';
            this._facilityName = result.facilityName || '';
            this._visitDate = result.visitDate || '';
            this._visitCardDescription = result.visitCardDescription || '';
            this._visitUtterance = result.visitUtterance || '';
            this._taskSubject = result.taskSubject || '';
            this._taskDueDate = result.taskDueDate || '';
            this._taskCardDescription = result.taskCardDescription || '';
            this._taskUtterance = result.taskUtterance || '';
            this._expenseType = result.expenseType || '';
            this._expenseAmount = result.expenseAmount || '';
            this._expenseDescription = result.expenseDescription || '';
            this._expenseCardDescription = result.expenseCardDescription || '';
            this._expenseUtterance = result.expenseUtterance || '';

        } catch (e) {
            console.error('processTranscript error:', e);
            this.aiSummary = text;
        }
        this.isLoadingSummary = false;

        this.suggestions = this._buildSuggestions();
        this.isLoadingSuggestions = false;
    }

    _resetExtractedEntities() {
        this._doctorName = '';
        this._facilityName = '';
        this._visitDate = '';
        this._visitCardDescription = '';
        this._visitUtterance = '';
        this._taskSubject = '';
        this._taskDueDate = '';
        this._taskCardDescription = '';
        this._taskUtterance = '';
        this._expenseType = '';
        this._expenseAmount = '';
        this._expenseDescription = '';
        this._expenseCardDescription = '';
        this._expenseUtterance = '';
    }

    _buildSuggestions() {
        const sug = [];
        let cid = 0;

        const visitChips = [];
        if (this._doctorName) {
            visitChips.push({ id: 'c' + cid++, label: 'Doctor: ' + this._doctorName, cls: 'chip chip-green' });
        }
        if (this._facilityName) {
            visitChips.push({ id: 'c' + cid++, label: 'Place: ' + this._facilityName, cls: 'chip chip-blue' });
        }
        if (this._visitDate) {
            visitChips.push({ id: 'c' + cid++, label: 'Date: ' + this._visitDate, cls: 'chip chip-green' });
        }

        let visitDesc;
        if (this._visitCardDescription) {
            visitDesc = this._visitCardDescription;
        } else if (this._doctorName && this._facilityName) {
            visitDesc = 'Dr. ' + this._doctorName + ' · ' + this._facilityName;
        } else if (this._doctorName) {
            visitDesc = 'Dr. ' + this._doctorName;
        } else if (this._facilityName) {
            visitDesc = this._facilityName;
        } else {
            visitDesc = 'Log this visit with AI summary';
        }

        sug.push({
            id: 'sug-visit', type: 'visit', title: 'Log Visit',
            description: visitDesc,
            cardClass: 'sug-card sug-border-green',
            iconClass: 'sug-icon sug-icon-green',
            titleClass: 'sug-title sug-title-green',
            isVisit: true, isTask: false, isExpense: false,
            hasChips: visitChips.length > 0, chips: visitChips
        });

        if (this._taskSubject) {
            const taskChips = [];
            if (this._doctorName) {
                taskChips.push({ id: 'c' + cid++, label: 'Doctor: ' + this._doctorName, cls: 'chip chip-purple' });
            }
            if (this._taskDueDate) {
                taskChips.push({ id: 'c' + cid++, label: 'Due: ' + this._taskDueDate, cls: 'chip chip-purple' });
            }

            sug.push({
                id: 'sug-task', type: 'task', title: 'Create Task',
                description: this._taskCardDescription || this._taskSubject,
                cardClass: 'sug-card sug-border-purple',
                iconClass: 'sug-icon sug-icon-purple',
                titleClass: 'sug-title sug-title-purple',
                isVisit: false, isTask: true, isExpense: false,
                hasChips: taskChips.length > 0, chips: taskChips
            });
        }

        if (this._expenseType || this._expenseAmount || this._expenseDescription) {
            const expChips = [];
            if (this._expenseDescription) {
                expChips.push({ id: 'c' + cid++, label: 'Name: ' + this._expenseDescription, cls: 'chip chip-amber' });
            }
            if (this._expenseAmount) {
                expChips.push({ id: 'c' + cid++, label: 'Amount: ₹' + this._expenseAmount, cls: 'chip chip-amber' });
            }
            if (this._expenseType) {
                expChips.push({ id: 'c' + cid++, label: 'Type: ' + this._expenseType, cls: 'chip chip-amber' });
            }

            const expDesc = this._expenseCardDescription
                || this._expenseDescription
                || (this._doctorName ? 'Expense for visit with Dr. ' + this._doctorName : 'Business expense');

            sug.push({
                id: 'sug-expense', type: 'expense', title: 'Log Expense',
                description: expDesc,
                cardClass: 'sug-card sug-border-amber',
                iconClass: 'sug-icon sug-icon-amber',
                titleClass: 'sug-title sug-title-amber',
                isVisit: false, isTask: false, isExpense: true,
                hasChips: expChips.length > 0, chips: expChips
            });
        }

        return sug;
    }

    // ═══════════════════════════════════════════════════════
    //  SUGGESTION → AGENT
    // ═══════════════════════════════════════════════════════

    handleSuggestionClick(event) {
        const sugType = event.currentTarget.dataset.type;
        const utterance = this._getAgentUtterance(sugType);

        if (!utterance) {
            this._toast('Not enough info', 'Could not build agent request.', 'warning');
            return;
        }

        if (sugType === 'expense') {
            this.showExpenseModal = true;
        } else {
            this.pendingUtterance = utterance;
            this.isModalOpen = true;
        }
    }

    _getAgentUtterance(sugType) {
        if (sugType === 'visit') {
            if (this._visitUtterance) {
                return this._visitUtterance;
            }
            const doctor = this._doctorName ? `Dr. ${this._doctorName}` : 'unknown doctor';
            const facility = this._facilityName || 'unknown facility';
            const notes = this.aiSummary || this.transcript || '';
            return `Help me log a visit with ${doctor} at ${facility}. Notes: ${notes}`;
        }

        if (sugType === 'task') {
            if (this._taskUtterance) {
                return this._taskUtterance;
            }
            let utt = `Help me create a task: ${this._taskSubject || 'follow-up'}`;
            if (this._taskDueDate) {
                utt += ` due ${this._taskDueDate}`;
            }
            return utt;
        }

        if (sugType === 'expense') {
            if (this._expenseUtterance) {
                return this._expenseUtterance;
            }
            let utt = `Help me log an expense`;
            if (this._expenseDescription) {
                utt += ` for ${this._expenseDescription}`;
            }
            if (this._expenseAmount) {
                utt += ` — ₹${this._expenseAmount}`;
            }
            if (this._expenseType) {
                utt += ` under ${this._expenseType}`;
            }
            return utt;
        }

        return '';
    }

    // ═══════════════════════════════════════════════════════
    //  MODAL EVENTS
    // ═══════════════════════════════════════════════════════

    handleModalClose(event) {
        if (event?.detail?.sessionId) {
            this.agentSessionId = event.detail.sessionId;
        }
        this.isModalOpen = false;
        this.pendingUtterance = '';
        this.showExpenseModal = false;
        this.uploadedFiles = [];
    }

    /**
     * Public API: open the expense modal for a suggestion and return a promise-like flow.
     * The method sets isModalOpen = true and resolves by dispatching a single
     * 'expensehandled' CustomEvent from this component when the user either confirms
     * sending to agent or dismisses the modal.
     *
     * Usage from parent:
     *  const modal = this.template.querySelector('c-visit-logger-with-expense');
     *  modal.openForSuggestion().then(result => { if (result.proceed) ... });
     */
    @api
    openForSuggestion() {
        // Show modal and return a promise that resolves when modal completes.
        this.isModalOpen = true;

        return new Promise((resolve) => {
            // One-time handler
            const handler = (evt) => {
                // The event should contain { proceed: boolean, utterance?: string, sessionId?: string }
                try {
                    const payload = evt.detail || {};
                    resolve({
                        proceed: payload.proceed === true,
                        utterance: payload.utterance || this._expenseUtterance || '',
                        sessionId: payload.sessionId || this.agentSessionId || null
                    });
                } finally {
                    this.removeEventListener('expensehandled', handler);
                    this.removeEventListener('close', handler);
                }
            };

            // Listen for a custom expensehandled event (preferred) or close as fallback.
            this.addEventListener('expensehandled', handler);
            this.addEventListener('close', handler);
        });
    }

    handleSessionUpdate(event) {
        this.agentSessionId = event.detail.sessionId;
    }

    // ═══════════════════════════════════════════════════════
    //  BOTTOM ACTIONS
    // ═══════════════════════════════════════════════════════

    handleRecordAnother() {
        this._endSession();
        this._cleanupRecording();
        this._resetState();
        this._setState(STATE.DEFAULT);
        this.dispatchEvent(new CustomEvent('visitsaved', {
            bubbles: false, composed: false
        }));
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.startRecording();
        }, 100);
    }

    handleFinish() {
        this._endSession();
        this._cleanupRecording();
        this._resetState();
        this._setState(STATE.DEFAULT);
        this.dispatchEvent(new CustomEvent('visitsaved', {
            bubbles: false, composed: false
        }));
    }

    // ── Handle File Upload Finished
    handleUploadFinished(event) {
        const uploadedFiles = event.detail.files;

        // Store ContentDocument IDs from lightning-file-upload
        this.uploadedFiles = uploadedFiles.map(file => ({
            documentId: file.documentId,
            name: file.name
        }));

        this.dispatchEvent(
            new ShowToastEvent({
                title: 'Success',
                message: `${uploadedFiles.length} file(s) uploaded successfully`,
                variant: 'success'
            })
        );

        // Automatically call agent with uploaded files
        const fileNames = this.uploadedFiles.map(f => {
            const lastDot = f.name.lastIndexOf('.');
            return lastDot > -1 ? f.name.substring(0, lastDot) : f.name;
        }).join(', ');
        let utterance = `I have uploaded expense receipt(s): "${fileNames}". Create the expense record for me.`;
        
        if (this._doctorName) {
            utterance = `I have uploaded expense receipt(s): "${fileNames}" for Dr. ${this._doctorName}. Create the expense record for me.`;
        }
        
        this.pendingUtterance = utterance;
        this.showExpenseModal = false;
        
        // Wait 1 second before opening agent modal
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isModalOpen = true;
        }, 1000);
    }

    handleExpenseSelect(event) {
        const button = event.currentTarget.dataset.button;
        console.log('button selected:', button);
    }

    // ═══════════════════════════════════════════════════════
    //  STATE
    // ═══════════════════════════════════════════════════════

    _setState(newState) {
        this.componentState = newState;
        this.dispatchEvent(new CustomEvent('statechange', {
            detail: newState, bubbles: false, composed: false
        }));
    }

    _resetState() {
        this.transcript = '';
        this.aiSummary = '';
        this.suggestions = [];
        this.isLoadingSummary = true;
        this.isLoadingSuggestions = true;
        this._finalTranscriptParts = [];
        this.elapsedSeconds = 0;
        this._resetExtractedEntities();
    }

    _endSession() {
        this.agentSessionId = null;
        this.isModalOpen = false;
        this.pendingUtterance = '';
    }

    _toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}