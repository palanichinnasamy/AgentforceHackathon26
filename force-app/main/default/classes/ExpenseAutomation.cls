/**
 * @description Automation class for managing Expense records and their related Line Items.
 *              This class provides invocable methods for Flow/Process Builder integration.
 * @author Salesforce Developer
 * @date 2026
 */
public with sharing class ExpenseAutomation {
    
    private static String output = '';
    private static Boolean lineItemsFound = false;
    
    /**
     * @description Wrapper class to receive expense data from Flow/Process Builder.
     */
    public class ParentExpenseWrapper{
        @InvocableVariable
        public String expenseName;
        
        @InvocableVariable
        public Decimal totalAmount;
        
        @InvocableVariable
        public String vendorStoreName;
        
        @InvocableVariable
        public Date transactionDate;
        
        @InvocableVariable
        public String expenseType;
        
        @InvocableVariable
        public String receiptNumber;
        
        @InvocableVariable
        public String lineItems;
        
        @InvocableVariable
        public String expenseId;
    }
    
    private static ParentExpenseWrapper input;
    
    /**
     * @description Invocable method to manage expense records and their line items.
     * @param inputs List of ParentExpenseWrapper containing expense data
     * @return List<String> containing success/error messages for Flow display
     */
    @InvocableMethod(label = 'Manage Expenses and Line Items')
    public static List<String> manageExpenses(List<ParentExpenseWrapper> inputs)
    {    
        try
        {    
            input = inputs[0];
            String finalExpenseId;
            
            // Case 1: expenseId is blank - create new expense
            if (string.isblank(input.expenseId)) {
                finalExpenseId = createExpenseRecord();
                output = 'Successfully created expense. Expense ID: ' + finalExpenseId;
            }
            // Case 2: expenseId is provided - use existing expense
            else {
                finalExpenseId = input.expenseId;
                output = 'Using existing Expense ID: ' + finalExpenseId;
            }
            
            // Create line items if provided
            if (!string.isblank(input.lineItems)) {
                Integer successCount = createLineItemsForExpense(finalExpenseId);
                output = output + '. Created ' + successCount + ' line items';
            }
            
        } catch (Exception e) {
            output = 'Error: ' + e.getMessage();
            System.debug('Exception: ' + e);
        }
        return new List<String>{output};
    }
    
    /**
     * @description Creates a new Expense__c record using data from the input wrapper.
     * @return String The ID of the newly created expense record
     */
    private static String createExpenseRecord()
    {
        Expense__c expenseToCreate = new Expense__c(
            Name = input.expenseName,
            Total_Amount_Spent__c = input.totalAmount,
            Vendor_Store__c = input.vendorStoreName,
            Transaction_Date__c = input.transactionDate,
            Receipt_Invoice__c = input.receiptNumber,
            Expense_Type__c = input.expenseType
        );
        Database.SaveResult result = Database.insert(expenseToCreate, false);
        return result.getId();
    }
    
    /**
     * @description Parses the lineItems JSON string and creates Expense_Line_Item__c records.
     * @param expenseId The ID of the parent Expense__c record
     * @return Integer The count of successfully created line items
     */
    private static Integer createLineItemsForExpense(String expenseId)
    {
        List<Expense_Line_Item__c> lineItemsToCreate = new List<Expense_Line_Item__c>();
        
        for (Object obj : (List<Object>) JSON.deserializeUntyped(input.lineItems)) {
            Map<String, Object> recordMap = (Map<String, Object>) obj;
            lineItemsToCreate.add(new Expense_Line_Item__c(
                Name = (String) recordMap.get('name'),
                Amount__c = Decimal.valueOf(String.valueOf(recordMap.get('amount'))),
                Expense__c = expenseId
            ));
        }
        
        Integer successCount = 0;
        if (!lineItemsToCreate.isEmpty()) {
            List<Database.SaveResult> lineItemResults = Database.insert(lineItemsToCreate, false);
            for (Database.SaveResult sr : lineItemResults) {
                if (sr.isSuccess()) successCount++;
            }
            lineItemsFound = successCount == lineItemsToCreate.size();
        }
        return successCount;
    }
}