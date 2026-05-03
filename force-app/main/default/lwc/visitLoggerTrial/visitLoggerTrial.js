import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import getDashboardStats from '@salesforce/apex/VisitLoggerController.getDashboardStats';
import isAgentActive from '@salesforce/apex/PostVisitAgentInvoker.isAgentActive';

export default class VisitLoggerTrial extends NavigationMixin(LightningElement) {

    visitsThisWeek = 0;
    visitsThisMonth = 0;
    openTasks = 0;
    expenseThisMonth = 0;
    showExpenseModal = false;
    uploadedFiles = [];
    doctorName = '';
    
    // Agent integration
    isModalOpen = false;
    pendingUtterance = '';
    agentSessionId = null;
    isAgentActive = false;

    get formattedExpense() {
        const val = this.expenseThisMonth || 0;
        if (val >= 100000) {
            return '₹' + (val / 100000).toFixed(1) + 'L';
        }
        if (val >= 1000) {
            return '₹' + (val / 1000).toFixed(1) + 'k';
        }
        return '₹' + Math.round(val);
    }

    @wire(getDashboardStats)
    wiredStats({ data, error }) {
        if (data) {
            this.visitsThisWeek   = data.visitsThisWeek   || 0;
            this.visitsThisMonth  = data.visitsThisMonth  || 0;
            this.openTasks        = data.openTasks         || 0;
            this.expenseThisMonth = data.expenseThisMonth  || 0;
        }
        if (error) {
            console.error('Dashboard stats error:', error);
        }
    }

    // ── Load Agent Status
    connectedCallback() {
        this._loadAgentStatus();
    }

    async _loadAgentStatus() {
        try {
            this.isAgentActive = await isAgentActive();
        } catch (e) {
            console.error('Failed to load agent status:', e);
            this.isAgentActive = false;
        }
    }

    get isSubmitDisabled() {
        return this.uploadedFiles.length === 0;
    }

    // ── Log Visit → Visits tab (voice recorder)
    handleLogVisit() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Visits_with_File_Upload'
            }
        });
    }

    // ── My Visits → Visit__c list view
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

    // ── Log Expense → Show expense modal
    handleLogExpense() {
        this.showExpenseModal = true;
        this.uploadedFiles = [];
    }

    // ── Handle Select Manual → Navigate to standard Expense creation
    handleSelectManual() {
        this.showExpenseModal = false;
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Expense__c',
                actionName: 'new'
            }
        });
    }

    // ── My Expenses → Expense list view
    handleMyExpenses() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Expense__c',
                actionName: 'list'
            },
            state: { filterName: 'Recent' }
        });
    }

    // ── New Task → OOB new Task
    handleNewTask() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Task',
                actionName: 'new'
            }
        });
    }

    // ── All Tasks → Task list view
    handleAllTasks() {
        this[NavigationMixin.Navigate]({
            type: 'standard__objectPage',
            attributes: {
                objectApiName: 'Task',
                actionName: 'list'
            },
            state: { filterName: 'Recent' }
        });
    }

    // ── Handle Modal Close (both expense and agent modals)
    handleModalClose(event) {
        if (event?.detail?.sessionId) {
            // Agent modal close
            this.agentSessionId = event.detail.sessionId;
            this.isModalOpen = false;
            this.pendingUtterance = '';
            this.doctorName = '';
        } else {
            // Expense modal close
            this.showExpenseModal = false;
            this.uploadedFiles = [];
            this.doctorName = '';
        }
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
        
        if (this.doctorName && this.doctorName.trim()) {
            utterance = `I have uploaded expense receipt(s): "${fileNames}" for Dr. ${this.doctorName}. Create the expense record for me.`;
        }
        
        this.pendingUtterance = utterance;
        this.showExpenseModal = false;
        
        // Wait 1 second before opening agent modal
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => {
            this.isModalOpen = true;
        }, 1000);
    }

    // ── Handle Session Update
    handleSessionUpdate(event) {
        this.agentSessionId = event.detail.sessionId;
    }
}