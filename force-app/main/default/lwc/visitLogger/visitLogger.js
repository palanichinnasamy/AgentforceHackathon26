import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { NavigationMixin } from 'lightning/navigation';
import Id from '@salesforce/user/Id';

import processTranscript from '@salesforce/apex/VisitLoggerController.processTranscript';
import regenerateSuggestions from '@salesforce/apex/VisitLoggerController.regenerateSuggestions';
import isAgentActive from '@salesforce/apex/PostVisitAgentInvoker.isAgentActive';

const STATE = {
    DEFAULT:    'default',
    RECORDING:  'recording',
    REVIEW:     'review'
};

export default class VisitLogger extends NavigationMixin(LightningElement) {

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
    isLoadingSummary = true;
    isLoadingSuggestions = true;

    // ═══ Edit-summary state ═══
    isEditingSummary = false;
    lastSavedSummary = '';
    isReextracting = false;
    _editingDraft = '';

    // Extracted entities
    _doctorName = '';
    _facilityName = '';
    _visitDate = '';
    _visitDateISO = '';
    _visitCardDescription = '';
    _taskSubject = '';
    _taskDueDate = '';
    _taskDueDateISO = '';
    _taskCardDescription = '';
    _expenseType = '';
    _expenseAmount = '';
    _expenseDescription = '';
    _expenseCardDescription = '';

    isModalOpen = false;
    pendingUtterance = '';
    agentSessionId = null;
    isAgentActive = false;

    // ═══════════════════════════════════════════════════════
    //  GETTERS
    // ═══════════════════════════════════════════════════════

    get isDefaultState()    { return this.componentState === STATE.DEFAULT; }
    get isRecording()       { return this.componentState === STATE.RECORDING; }
    get isReviewState()     { return this.componentState === STATE.REVIEW; }
    get hasSuggestions()    { return this.suggestions && this.suggestions.length > 0; }
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

    get canShowEditButton() {
        return !this.isLoadingSummary
            && !this.isEditingSummary
            && Boolean(this.aiSummary);
    }

    get suggestionsWrapperClass() {
        return this.isReextracting
            ? 'suggestions-wrapper suggestions-locked'
            : 'suggestions-wrapper';
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

    renderedCallback() {
        // Pre-fill the textarea on first render of edit mode.
        // textarea doesn't accept `value` as an LWC attribute, so we
        // imperatively set the DOM .value once the ref is available.
        if (this.isEditingSummary) {
            const ta = this.refs?.summaryEditField;
            if (ta && ta.value !== this._editingDraft) {
                ta.value = this._editingDraft;
            }
        }
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
    //  PROCESS TRANSCRIPT (FIRST PASS)
    // ═══════════════════════════════════════════════════════

    async _processVisitTranscript() {
        const text = this.transcript || '';

        this.isLoadingSummary = true;
        this.isLoadingSuggestions = true;
        this.aiSummary = '';
        this.lastSavedSummary = '';
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
            this.lastSavedSummary = this.aiSummary;
            this._applyExtractedEntities(result);
        } catch (e) {
            console.error('processTranscript error:', e);
            this.aiSummary = text;
            this.lastSavedSummary = text;
        }
        this.isLoadingSummary = false;

        this.suggestions = this._buildSuggestions();
        this.isLoadingSuggestions = false;
    }

    _applyExtractedEntities(result) {
        this._doctorName             = result.doctorName || '';
        this._facilityName           = result.facilityName || '';
        this._visitDate              = result.visitDate || '';
        this._visitDateISO           = result.visitDateISO || '';
        this._visitCardDescription   = result.visitCardDescription || '';
        this._taskSubject            = result.taskSubject || '';
        this._taskDueDate            = result.taskDueDate || '';
        this._taskDueDateISO         = result.taskDueDateISO || '';
        this._taskCardDescription    = result.taskCardDescription || '';
        this._expenseType            = result.expenseType || '';
        this._expenseAmount          = result.expenseAmount || '';
        this._expenseDescription     = result.expenseDescription || '';
        this._expenseCardDescription = result.expenseCardDescription || '';
    }

    _resetExtractedEntities() {
        this._applyExtractedEntities({});
    }

    // ═══════════════════════════════════════════════════════
    //  EDIT SUMMARY
    // ═══════════════════════════════════════════════════════

    handleEditSummary() {
        this._editingDraft = this.aiSummary || '';
        this.isEditingSummary = true;
    }

    handleSummaryDraftChange(event) {
        this._editingDraft = event.target.value;
    }

    handleCancelSummary() {
        this._editingDraft = '';
        this.isEditingSummary = false;
    }

    async handleSaveSummary() {
        const newText = (this._editingDraft || '').trim();

        if (!newText) {
            this._toast('Empty summary', 'Please enter some text or cancel.', 'warning');
            return;
        }

        // No-op edit — skip the LLM round-trip
        if (newText === (this.lastSavedSummary || '').trim()) {
            this.isEditingSummary = false;
            this._editingDraft = '';
            return;
        }

        this.isReextracting = true;

        try {
            const result = await regenerateSuggestions({ editedSummary: newText });
            // User-edited summary is authoritative — DO NOT overwrite from result
            this.aiSummary = newText;
            this.lastSavedSummary = newText;
            this._applyExtractedEntities(result);
            this.suggestions = this._buildSuggestions();
            this.isEditingSummary = false;
            this._editingDraft = '';
        } catch (e) {
            console.error('regenerateSuggestions error:', e);
            const msg = e?.body?.message || e?.message || 'Re-extraction failed.';
            this._toast('Re-extract failed', msg, 'error');
            // Keep edit mode open so user can retry or cancel
        } finally {
            this.isReextracting = false;
        }
    }

    // ═══════════════════════════════════════════════════════
    //  BUILD SUGGESTIONS
    // ═══════════════════════════════════════════════════════

    _buildSuggestions() {
        const sug = [];
        let cid = 0;

        // VISIT card — show only if doctor or facility was extracted
        if (this._doctorName || this._facilityName) {
            const visitChips = [];
            if (this._doctorName) {
                visitChips.push({ id: 'c' + cid++, label: 'Doctor: ' + this._doctorName, cls: 'chip chip-green' });
            }
            if (this._facilityName) {
                visitChips.push({ id: 'c' + cid++, label: 'Facility: ' + this._facilityName, cls: 'chip chip-blue' });
            }
            if (this._visitDate) {
                visitChips.push({ id: 'c' + cid++, label: 'Date: ' + this._visitDate, cls: 'chip chip-green' });
            }

            let visitDesc;
            if (this._visitCardDescription) {
                visitDesc = this._visitCardDescription;
            } else if (this._doctorName && this._facilityName) {
                visitDesc = 'Visit with Dr. ' + this._doctorName + ' at ' + this._facilityName;
            } else if (this._doctorName) {
                visitDesc = 'Visit with Dr. ' + this._doctorName;
            } else {
                visitDesc = 'Visit at ' + this._facilityName;
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
        }

        // TASK card — show if any task entity extracted (doctor optional)
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

        // EXPENSE card — show if any expense entity extracted
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
    //  SUGGESTION → AGENT (STRUCTURED UTTERANCE)
    // ═══════════════════════════════════════════════════════

    handleSuggestionClick(event) {
        if (this.isReextracting) {
            return;
        }
        const sugType = event.currentTarget.dataset.type;
        const utterance = this._buildStructuredUtterance(sugType);

        if (!utterance) {
            this._toast('Not enough info', 'Could not build agent request.', 'warning');
            return;
        }

        this.pendingUtterance = utterance;
        this.isModalOpen = true;
    }

    /**
     * Build the "Help me log a Visit/Task/Expense with below details -" string.
     * Format: one field per line, "Field Name: Field Value".
     * Skips fields with no value. Dates output in DD/MM/YYYY (display only).
     */
    _buildStructuredUtterance(sugType) {
        const lines = [];

        if (sugType === 'visit') {
            lines.push('Help me log a Visit with below details -');
            if (this._doctorName)   { lines.push('Doctor: Dr. ' + this._doctorName); }
            if (this._facilityName) { lines.push('Facility: ' + this._facilityName); }

            const visitDate = this._formatDateForDisplay(this._visitDateISO, this._visitDate);
            if (visitDate) { lines.push('Visit Date: ' + visitDate); }

            const notes = (this.aiSummary || this.transcript || '').trim();
            if (notes) { lines.push('Visit Notes: ' + notes); }

            return lines.length > 1 ? lines.join('\n') : '';
        }

        if (sugType === 'task') {
            lines.push('Help me create a Task with below details -');
            if (this._taskSubject) { lines.push('Subject: ' + this._taskSubject); }
            if (this._doctorName)  { lines.push('Doctor: Dr. ' + this._doctorName); }

            const due = this._formatDateForDisplay(this._taskDueDateISO, this._taskDueDate);
            if (due) { lines.push('Due Date: ' + due); }

            const desc = (this._taskCardDescription || this.aiSummary || '').trim();
            if (desc) { lines.push('Description: ' + desc); }

            return lines.length > 1 ? lines.join('\n') : '';
        }

        if (sugType === 'expense') {
            lines.push('Help me log an Expense with below details -');
            if (this._expenseDescription) { lines.push('Description: ' + this._expenseDescription); }
            if (this._expenseAmount)      { lines.push('Amount: ₹' + this._expenseAmount); }
            if (this._expenseType)        { lines.push('Type: ' + this._expenseType); }
            if (this._facilityName)       { lines.push('Facility: ' + this._facilityName); }

            return lines.length > 1 ? lines.join('\n') : '';
        }

        return '';
    }

    /**
     * Convert YYYY-MM-DD to DD/MM/YYYY for display in the agent utterance.
     * Falls back to the natural-phrase visitDate/taskDueDate if no ISO available.
     * Returns empty string if neither is present.
     */
    _formatDateForDisplay(iso, fallbackPhrase) {
        if (iso && /^\d{4}-\d{2}-\d{2}$/.test(iso)) {
            const [y, m, d] = iso.split('-');
            return `${d}/${m}/${y}`;
        }
        return fallbackPhrase || '';
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
        this.lastSavedSummary = '';
        this.suggestions = [];
        this.isLoadingSummary = true;
        this.isLoadingSuggestions = true;
        this.isEditingSummary = false;
        this.isReextracting = false;
        this._editingDraft = '';
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