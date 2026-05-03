import { LightningElement, api } from 'lwc';

export default class AgentFileUpload extends LightningElement {
    @api recordId;
    @api readOnly;
    fileName = '';
    _value = {};

    @api 
    get value() { return this._value; }
    set value(val) { this._value = val || {}; }

    get acceptedFormats() {
        return ['.pdf', '.png', '.jpg'];
    }

    handleUploadFinished(event){
        const uploadedFiles = event.detail.files;
        if (uploadedFiles.length > 0) {
            this.fileName = uploadedFiles[0].name;
            this._value = { 
                documentId: uploadedFiles[0].documentId,
                name: uploadedFiles[0].name 
            };

            // CRITICAL: Notify Agentforce of the new value
            this.dispatchEvent(new CustomEvent("valuechange", {
                detail: { value: this._value },
                bubbles: true,
                composed: true
            }));
        }
    }
}