import { api, LightningElement } from 'lwc';

export default class CustomModal extends LightningElement {
    @api header;
    @api headerContent;
    @api bodyContent;
    @api imageContent;
    @api footerContent;
    @api footerButtons;
    @api bodySlot;

    get bodyFound(){
        return this.bodyContent || this.imageContent || this.bodySlot;
    }

    get headerFound(){
        return this.header || this.headerContent;
    }

    get footerFound(){
        return this.footerContent || this.footerButtons;
    }

    handleClose(){
        this.dispatchEvent(new CustomEvent("close"));
    }

    handleClick(event){
        const button = event.target.dataset.value;
        this.dispatchEvent(new CustomEvent("buttonclick", { 
            detail: { buttonValue: button } 
        }));
    }
}