import { LightningElement, api } from 'lwc';

const OPTIONS_REGEX = /<OPTIONS>\s*([\s\S]*?)\s*<\/OPTIONS>/i;

/**
 * The agent sometimes wraps its response in a JSON object like:
 *   {"type":"Text","value":"Hello world"}
 * This helper unwraps it and returns just the value.
 * If the input is not a JSON wrapper, returns it as-is.
 */
function unwrapAgentResponse(rawText) {
    if (!rawText || typeof rawText !== 'string') {
        return rawText || '';
    }

    const trimmed = rawText.trim();

    // Quick check: only attempt parse if it looks like a JSON object
    if (!trimmed.startsWith('{') || !trimmed.endsWith('}')) {
        return rawText;
    }

    try {
        const parsed = JSON.parse(trimmed);
        if (parsed && typeof parsed === 'object' && typeof parsed.value === 'string') {
            return parsed.value;
        }
    } catch (e) {
        // Not valid JSON — return original
    }

    return rawText;
}

export default class AgentMessage extends LightningElement {

    @api message;       // { id, role: 'user'|'agent'|'typing'|'success', text }
    @api userName = 'You';
    @api agentName = 'Field Assistant';
    @api isLocked = false;

    _parsed = null;

    // ═══ ROLE GETTERS ═══

    get isUser()    { return this.message?.role === 'user'; }
    get isAgent()   { return this.message?.role === 'agent'; }
    get isTyping()  { return this.message?.role === 'typing'; }
    get isSuccess() { return this.message?.role === 'success'; }

    // ═══ PARSING (memoized) ═══

    _parse() {
        if (this._parsed) {
            return this._parsed;
        }

        // First unwrap any JSON wrapper from the agent
        const text = unwrapAgentResponse(this.message?.text || '');
        const match = text.match(OPTIONS_REGEX);

        if (!match) {
            this._parsed = { cleanedText: text, options: [] };
            return this._parsed;
        }

        let optionsArray = [];
        try {
            const parsed = JSON.parse(match[1]);
            if (Array.isArray(parsed)) {
                optionsArray = parsed
                    .filter(o => typeof o === 'string' && o.trim())
                    .map(o => o.trim());
            }
        } catch (e) {
            console.warn('Failed to parse OPTIONS JSON:', e);
            this._parsed = { cleanedText: text, options: [] };
            return this._parsed;
        }

        const cleaned = text.replace(OPTIONS_REGEX, '').trim();
        this._parsed = { cleanedText: cleaned, options: optionsArray };
        return this._parsed;
    }

    get cleanedText() {
        return this._parse().cleanedText;
    }

    get hasOptions() {
        return this._parse().options.length > 0;
    }

    get numberedOptions() {
        return this._parse().options.map((label, idx) => ({
            number: idx + 1,
            label
        }));
    }

    // ═══ EVENTS ═══

    handleOptionClick(event) {
        const number = parseInt(event.currentTarget.dataset.number, 10);
        const opt = this.numberedOptions.find(o => o.number === number);
        if (!opt) {
            return;
        }

        const reply = `${opt.number}. ${opt.label}`;

        this.dispatchEvent(new CustomEvent('optionselected', {
            detail: { number: opt.number, label: opt.label, reply },
            bubbles: true,
            composed: true
        }));
    }
}