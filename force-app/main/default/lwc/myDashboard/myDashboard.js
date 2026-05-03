import { LightningElement, wire } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getDashboardStats from '@salesforce/apex/VisitLoggerController.getDashboardStats';

export default class MyDashboard extends NavigationMixin(LightningElement) {

    visitsThisWeek = 0;
    visitsThisMonth = 0;
    openTasks = 0;
    expenseThisMonth = 0;

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

    // ── Log Visit → Visits tab (voice recorder)
    handleLogVisit() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Visits'
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

    // ── Log Expense → OOB new Expense
    handleLogExpense() {
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
}