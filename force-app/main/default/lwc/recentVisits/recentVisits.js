import { LightningElement, wire, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { refreshApex } from '@salesforce/apex';

import getRecentVisits from '@salesforce/apex/VisitLoggerController.getRecentVisits';
import getRecentVisitFieldSet from '@salesforce/apex/VisitLoggerController.getRecentVisitFieldSet';

export default class RecentVisits extends NavigationMixin(LightningElement) {

    fieldSetFields = [];
    recentVisits = [];
    isLoading = true;
    _wiredVisits;
    _fieldSetLoaded = false;
    _visitsLoaded = false;

    get isLoaded() {
        return !this.isLoading;
    }

    get hasRecentVisits() {
        return this.recentVisits && this.recentVisits.length > 0;
    }

    // ═══════════════════════════════════════════════════════
    //  WIRE
    // ═══════════════════════════════════════════════════════

    @wire(getRecentVisitFieldSet)
    wiredFieldSet({ data, error }) {
        if (data) {
            this.fieldSetFields = data;
        }
        if (error) {
            console.error('Field set error:', error);
        }
        this._fieldSetLoaded = true;
        this._checkLoading();
    }

    @wire(getRecentVisits)
    wiredVisits(result) {
        this._wiredVisits = result;
        if (result.data) {
            this.recentVisits = result.data;
        }
        if (result.error) {
            console.error('Recent visits error:', result.error);
        }
        this._visitsLoaded = true;
        this._checkLoading();
    }

    _checkLoading() {
        if (this._fieldSetLoaded && this._visitsLoaded) {
            this.isLoading = false;
        }
    }

    // ═══════════════════════════════════════════════════════
    //  PUBLIC API — called by parent container after save
    // ═══════════════════════════════════════════════════════

    @api
    refreshData() {
        this.isLoading = true;
        this._visitsLoaded = false;
        refreshApex(this._wiredVisits)
            .then(() => {
                this._visitsLoaded = true;
                this._checkLoading();
            })
            .catch((err) => {
                console.error('Refresh error:', err);
                this._visitsLoaded = true;
                this._checkLoading();
            });
    }

    // ═══════════════════════════════════════════════════════
    //  NAVIGATION
    // ═══════════════════════════════════════════════════════

    handleMyVisits() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Visit__c',
                actionName: 'list'
            },
            state: { filterName: 'Recent' }
        });
    }

    navigateToVisit(event) {
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: event.currentTarget.dataset.id,
                objectApiName: 'Visit__c',
                actionName: 'view'
            }
        });
    }
}