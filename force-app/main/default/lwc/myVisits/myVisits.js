import { LightningElement, wire } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';

export default class MyVisits extends LightningElement {

    showRecentVisits = true;
    _lastPageRefStamp = null;

    get recentVisitsClass() {
        return this.showRecentVisits ? 'recent-wrapper' : 'recent-wrapper hidden';
    }

    /**
     * @wire(CurrentPageReference) fires:
     *  - When component first mounts
     *  - When URL params change (autostart redirect)
     *  - When user taps the same tab again (in newer Salesforce versions)
     *
     * We use this to reset the Visit Logger to default state on
     * every entry, ensuring the tab always opens fresh.
     */
    @wire(CurrentPageReference)
    wiredPageRef(pageRef) {
        if (!pageRef) {
            return;
        }

        const autoStart = pageRef.state?.c__autostart === 'true'
            || pageRef.state?.autostart === 'true';

        // Stamp the page ref so we can detect re-navigations
        const stamp = JSON.stringify(pageRef);
        const isReNavigation = (this._lastPageRefStamp !== stamp);
        this._lastPageRefStamp = stamp;

        if (autoStart) {
            // Reserved for future use — currently no caller passes this
            this._tryStartFreshRecording();
        } else if (isReNavigation) {
            // Reset to default whenever user re-enters the tab
            this._tryResetToDefault();
        }
    }

    _tryStartFreshRecording(attempt = 0) {
        const visitLogger = this.template.querySelector('c-visit-logger');
        if (visitLogger && typeof visitLogger.resetAndStart === 'function') {
            visitLogger.resetAndStart();
        } else if (attempt < 10) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._tryStartFreshRecording(attempt + 1), 50);
        }
    }

    _tryResetToDefault(attempt = 0) {
        const visitLogger = this.template.querySelector('c-visit-logger');
        if (visitLogger && typeof visitLogger.resetToDefault === 'function') {
            visitLogger.resetToDefault();
        } else if (attempt < 10) {
            // eslint-disable-next-line @lwc/lwc/no-async-operation
            setTimeout(() => this._tryResetToDefault(attempt + 1), 50);
        }
    }

    handleStateChange(event) {
        const state = event.detail;
        this.showRecentVisits = (state === 'default');
    }

    handleVisitSaved() {
        this.showRecentVisits = true;
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            const recentVisitsComp = this.template.querySelector('c-recent-visits');
            if (recentVisitsComp) {
                recentVisitsComp.refreshData();
            }
        }, 0);
    }
}