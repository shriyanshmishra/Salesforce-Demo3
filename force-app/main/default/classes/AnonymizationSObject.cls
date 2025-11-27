/*=====================================================================================
*
* @purpose: This class Processes the sObject records In a batch and apply anonymize rules on the listed fields.
*
* @author:  Nitesh Mali (Sisodia) : nitesh.mali@oaknorth.com

* @history:
* version                   | author                       | changes
* ====================================================================================
* 1.0 (27.10.2017)          | nitesh.mali@oaknorth.com     | initial version
* 2.0 (2018-03-05)          | leo.pape@oaknorth.com        | improvements
* 
*/
global class AnonymizationSObject implements Database.Batchable<sObject>, Database.Stateful {
    public class AnonymizationSObjectException extends Exception {}
    
    // generic class for database results
    public class DatabaseResult {
        final Id recordId;
        final List<Database.Error> errors;
        final Boolean success;
        final String type;
        //public Id getId() { return recordId; }
        public List<Database.Error> getErrors() { return errors; }
        public Boolean isSuccess() { return success; }
        public String getType() { return type; }
        
        public DatabaseResult(STring type, Id recordId, List<Database.Error> errors, Boolean success) {
            this.type = type;
            this.recordId = recordId;
            this.errors = (errors != null) ? errors : new List<Database.Error>();
            this.success = success;
        }
        
        public DatabaseResult(Database.SaveResult result) { this('Save', result.getId(), result.getErrors(), result.isSuccess()); }
        //public DatabaseResult(Database.UpsertResult result) { this('Upsert', result.getId(), result.getErrors(), result.isSuccess()); }
        public DatabaseResult(Database.DeleteResult result) { this('Delete', result.getId(), result.getErrors(), result.isSuccess()); }
        //public DatabaseResult(Database.UndeleteResult result) { this('Undelete', result.getId(), result.getErrors(), result.isSuccess()); }
        public DatabaseResult(Database.EmptyRecycleBinResult result) { this('EmptyRecycleBin', result.getId(), result.getErrors(), result.isSuccess()); }
    }
    
    private final String query;
    private final String sObjectName;
    private final String sObjectConfigName;
    private final String whereClause;
    private final List<Anonymization_Field__c> fieldRules;
    private final List<String> fieldNames;
    private final List<String> historyFieldNames; // history field names can be different from 'normal' field names, so keeping separate list of those
    private final String historyObjectRelationshipFieldName;
    private final String historyObjectName;
    private List<Id> previousBatchRecordIDs; // store previous batch recordIDs, so we can later pass them to delete history records method
    private final Boolean hasAnonymizedField;
    private final Map<String, Schema.DisplayType> fieldDataTypes;
    private Boolean hasDMLErrors;
    
    private static Boolean runningInASandbox() {
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }
    
     // Constructor
    public AnonymizationSObject(String sObjectName, String whereClause, Boolean hasAnonymizedField) {
        if (!runningInASandbox() && !Test.isRunningTest() && String.isBlank(whereClause)) {// we don't want to accidentally run this with an empty where clause in production...
            throw new AnonymizationSObjectException ('WHERE clause is mandatory in production for sObject: ' + sObjectName);
        }
        if (AnonymizationConstants.SKIP_ANONYMIZE_ALL.contains(sObjectName.toLowerCase()) // make sure WHERE clause is sufficiently restrictive if the sObject is in the list of SKIP_ANONYMIZE_ALL
            && (String.isBlank(whereClause) || Pattern.Matches('^(?i)\\s*' + AnonymizationConstants.ANONYMIZED_FIELD_NAME + '\\s*=\\s*false\\s*$', whereClause))) {
            throw new AnonymizationSObjectException('WHERE clause is mandatory for sObject: ' + sObjectName);
        }
        this.sObjectName = sObjectName;
        this.whereClause = whereClause;
        this.hasAnonymizedField = hasAnonymizedField;
        this.hasDMLErrors = false;
        this.previousBatchRecordIDs = new List<Id>();
        
        // get lists of field describes for the sObjectName
        if(!Schema.getGlobalDescribe().containsKey(sObjectName)) {
            throw new AnonymizationSObjectException('No such object: ' + sObjectName);
        }
        Map<String, Schema.sObjectField> fields = Schema.getGlobalDescribe().get(sObjectName).getDescribe().fields.getMap();
        
        // set field names and data types
        this.fieldNames = new List<String>();
        this.historyFieldNames = new List<String>();
        this.fieldDataTypes = new Map<String, Schema.DisplayType>();
        this.fieldRules = [SELECT Field__c, Randomize__c, Truncate__c FROM Anonymization_Field__c WHERE sObject__c = :sObjectName];
        String fieldName;
        Schema.DisplayType fieldDataType;
        
        for (Anonymization_Field__c fieldRule : this.fieldRules) {
            fieldName = fieldRule.Field__c;
            if (!fields.containsKey(fieldName)) {
                throw new AnonymizationSObjectException('No such field on object: ' + sObjectName + '.' + fieldName);
            }
            fieldDataType = fields.get(fieldName).getDescribe().getType();
            
            this.fieldNames.add(fieldName);
            this.fieldDataTypes.put(fieldName, fieldDataType);
            // replace 'Name' with 'NameText' for the Account object, because 
            // Salesforce thought that would be a more helpful way to name fields in history records,
            // but then forgot to document that
            if (sObjectName.toLowerCase().equals('account') && fieldName.toLowerCase().equals('name')) {
                this.historyFieldNames.add('TextName');
            } else {
                this.historyFieldNames.add(fieldName);  
            }
        }
        
        if (this.sObjectName.endsWith('__c')) { 
            this.historyObjectName = this.sObjectName.left(this.sObjectName.length() - 1) + 'History';
        } else {
            if (sObjectName.equalsIgnoreCase('Opportunity')) {
                this.historyObjectName = 'OpportunityFieldHistory';
            } else {
                this.historyObjectName = this.sObjectName + 'History';
            }
        }
        this.historyObjectRelationshipFieldName = this.sObjectName.endsWith('__c') ? 'ParentId' : this.sObjectName + 'Id';
        
        // select query
        if (!fieldNames.isEmpty()) {
            this.query = 'SELECT ' + String.join(this.fieldNames, ', ') + ' FROM ' + sObjectName + ' ' + whereClause;
        } else {
            System.debug('No field rules found for sObject: ' + sObjectName);
            this.query = 'SELECT Id FROM ' + sObjectName + ' ' + whereClause;
        }
        
        // if the query is invalid, we log some details, then throw an exception;
        // this can caught more easily here (in the constructor) than in the start() method later on
        try {
            Database.Query(this.query + ' LIMIT 0');
        } catch (QueryException e) {
            System.debug('Invalid query for sObject: ' + sObjectName + ' query is: ' + this.query + '\n Query error is: ' + e.getMessage());
            throw e;
        }

        System.debug('Validated query is: ' + this.query);
        
    }
    
     // Generates random alpha numeric String
    private static String generateRandomString(Integer len, Integer[] options) {
        Integer[] chars = new Integer[]{};
        for (Integer i = 0; i < len; i++) {
            chars.add(options[Integer.valueOf(Math.random() * options.size())]);
        }
        return String.fromCharArray(chars);
    }

    // Takes an input string, and replaces each character that is not in 'skip' with a random option from 'replaceOptions'.
    // Processing starts after 'keep' characters, either from left to right (reverse = false) or from right to left (reverse = true).
    // 'replaceOptions' and 'skip' are lists of characters (ASCII codes).
    public static String replaceCharacters(String input, Integer[] replaceOptions, Integer[] skip, Integer keep, Boolean reverse) {
        Integer[] chars = input.getChars();
        if (reverse) {
            for (Integer i=chars.size()-1; i>=0; i--) {
                if (skip.contains(chars[i])) { keep++; continue; }
                if (chars.size() - i > keep) { chars[i] = replaceOptions[Integer.valueOf(Math.random() * replaceOptions.size())]; }
            }
        } else {
            for (Integer i=0; i<chars.size(); i++) {
                if (skip.contains(chars[i])) { keep++; continue; }
                if (i >= keep) { chars[i] = replaceOptions[Integer.valueOf(Math.random() * replaceOptions.size())]; }
            }
        }
       return String.fromCharArray(chars);
    }
    
    // returns the input number with 'keep' digits (from the left) and any remaining digits replaced with zeros
    private static String replaceDecimalWithZero(String input, Integer keep) {
       return replaceCharacters(input, AnonymizationConstants.ZERO, AnonymizationConstants.ZERO, keep, false);
    }
   
    // returns the input number with 'keep' digits (from the left) and any remaining digits replaced with random numbers
    private static String replaceDecimalWithRandom(String input, Integer keep) {
        return replaceCharacters(input, AnonymizationConstants.NUMERICS, AnonymizationConstants.NUMERICS_SEPARATORS, keep, false);
    }

    // returns input email with 'keep' characters (from the right) and any remaining characters replaced with random alphabetic characters 
    private static String replaceEmailWithRandom(String input, Integer keep) {
        return replaceCharacters(input, AnonymizationConstants.ALPHABETICS, AnonymizationConstants.EMAIL_SEPARATORS, keep, true);
    }

    // returns input url with 'keep' characters (from the right) and any remaining characters replaced with random alphabetic characters
    private static String replaceURLWithRandom(String input, Integer keep) {
        return replaceCharacters(input, AnonymizationConstants.ALPHABETICS, AnonymizationConstants.URL_SEPARATORS, keep, true);
    }

    // This method apply truncation rules on field based on field data type.
    public static void doTruncation(sObject record, String fieldName, Schema.DisplayType fieldDataType, Boolean randomize, Integer cutoff) {
        cutoff = cutoff == null ? 0 : cutoff; // Treat null length as zero
        String keepStr, replStr, newStr;

        Object origField = record.get(fieldName);
        if (origField == null) {
            return;
        }
        String origStr = String.valueOf(origField);
        Integer length = origStr.length();
        Integer keep = Math.min(length, cutoff);
        Integer replace = Math.max(0, length - keep);

        //system.debug(' The data type of  ' + record.getSObjectType().getDescribe().getName() + '.' + fieldName + ' ---> ' + fieldDataType);
        if (fieldDataType == Schema.DisplayType.String || fieldDataType == Schema.DisplayType.EncryptedString || fieldDataType == Schema.DisplayType.TextArea || fieldDataType == Schema.DisplayType.Phone) {
            keepStr = origStr.left(keep);
            replStr = randomize ? generateRandomString(replace, AnonymizationConstants.ALPHA_NUMERICS) : '';
            newStr = keepStr + replStr;
            record.put(fieldName, newStr);
        } else if (fieldDataType == Schema.DisplayType.Integer) {
            newStr = randomize ? replaceDecimalWithRandom(origStr, keep) : replaceDecimalWithZero(origStr, keep);
            record.put(fieldName, Integer.valueOf(newStr));
        } else if (fieldDataType == Schema.DisplayType.Double || fieldDataType == Schema.DisplayType.Currency || fieldDataType == Schema.DisplayType.Percent) {
            newStr = randomize ? replaceDecimalWithRandom(origStr, keep) : replaceDecimalWithZero(origStr, keep);
            record.put(fieldName, Decimal.valueOf(newStr));
        } else if (fieldDataType == Schema.DisplayType.DateTime) {
            if (randomize) {record.put(fieldName, (DateTime.valueOf(AnonymizationConstants.LOWEST_DATETIME_STRING))); } // TODO: implement proper datetime randomization
            else { record.put(fieldName, null); }
        } else if (fieldDataType == Schema.DisplayType.Date) {
            if (randomize) { record.put(fieldName, (Date.valueOf(AnonymizationConstants.LOWEST_DATE_STRING))); } // TODO: implement proper datetime randomization
            else { record.put(fieldName, null); }
        } else if (fieldDataType == Schema.DisplayType.Picklist || fieldDataType == Schema.DisplayType.MultiPicklist) { // does not support randomization (unlikely a picklist contains personal data anyway)
            record.put(fieldName, null);
        } else if (fieldDataType == Schema.DisplayType.Email) {
            record.put(fieldName, replaceEmailWithRandom(origStr, keep)); // emails always need to be randomized, otherwise an invalid email address may be returned
        } else if (fieldDataType == Schema.DisplayType.URL) {
            record.put(fieldName, replaceURLWithRandom(origStr, keep)); // urls always need to be randomized, otherwise an invalid url may be returned
        } else if(fieldDataType == Schema.DisplayType.Location) {
            fieldName = fieldName.replace('__c', '');
            record.put(fieldName + '__latitude__s', null);
            record.put(fieldName + '__longitude__s', null); 
        } else if(fieldDataType == Schema.DisplayType.Address) {
            // skip: address components are set separately
        } else {
            throw new AnonymizationSObjectException('Unhandled field type encountered: ' + fieldDataType + ' for Sobject and field: ' + record.getSObjectType().getDescribe().getName() + '.' + FieldName);
        }
    }
    
     // Deletes the related standard Salesforce child objects for a set of records
    // such as tasks, emails, events, content, etc.
    private Map<Id, DatabaseResult> deleteChildRecords(List<sObject> records) {
        List<sObject> deleteRecords = new List<sObject>();
        List<sObject> recycleRecords = new List<sObject>();
        List<Id> recordIDs = new List<Id>();
        
        // get list of IDs
        for (sObject record : records) {
            recordIDs.add(record.Id);
        }
        
        // activities
        List<sObject> tasks = [SELECT Id FROM Task WHERE whatId IN :recordIDs OR whoId IN :recordIDs OR AccountId IN :recordIDs];
        deleteRecords.addAll(tasks);
        recycleRecords.addAll(tasks);

        List<sObject> events = [SELECT Id FROM Event WHERE whatId IN :recordIDs OR whoId IN :recordIDs OR AccountId IN :recordIDs];
        deleteRecords.addAll(events);
        recycleRecords.addAll(events);
                
        // emails
        List<sObject> emails = [SELECT Id FROM EmailMessage WHERE ActivityId IN :tasks OR parentId IN :recordIDs OR relatedToId IN :recordIDs];
        deleteRecords.addAll(emails);
        // recycleRecords.addAll(emails); // email messages don't go to recycle bin
        
        // notes
        List<sObject> notes = [SELECT Id FROM Note WHERE parentId IN :recordIDs];
        deleteRecords.addAll(notes);
        recycleRecords.addAll(notes);
         
        // content documents
        List<ContentDocumentLink> contentDocumentLinks = [SELECT ContentDocument.Id, ContentDocument.title FROM ContentDocumentLink WHERE LinkedEntityId IN :recordIDs];
       
        Set<ID> documentIDSet = new Set<ID>();
        for(ContentDocumentLink contentdocmntlink : contentDocumentLinks) {
            documentIDSet.add(contentdocmntlink.ContentDocument.Id);
        }
        List<sObject> contentDocuments = [SELECT ID FROM ContentDocument WHERE ID IN :documentIDSet];
        deleteRecords.addAll(contentDocuments);
        recycleRecords.addAll(contentDocuments);
        
        // attachments
        List<sObject> attachments = [SELECT Id FROM Attachment WHERE parentId IN :recordIDs];
        deleteRecords.addAll(attachments);
        recycleRecords.addAll(attachments);

        // feeditem and feed comment
        List<sObject> feedItems = [SELECT Id FROM FeedItem WHERE parentId IN :recordIDs];
        deleteRecords.addAll(feedItems);
        //recycleRecords.addAll(feedItems); NB: feedItems are not recycled
        
        // feedComments get deleted with feedItem
        //List<FeedComment> comments = [SELECT Id FROM FeedComment WHERE FeedItemId IN :feedItems];
        //deleteRecords.addAll(comments);
        //recycleRecords.addAll(comments); NB: feedComments are not recycled
        
        // delete duplicate record sets where this record was a member of, assuming by the time anonymization runs the duplicate has been reviewed
        List<sObject> duplicates = [SELECT Id FROM DuplicateRecordSet WHERE Id IN (SELECT DuplicateRecordSetId FROM DuplicateRecordItem WHERE RecordId IN :recordIDs)];
        deleteRecords.addAll(duplicates);
        recycleRecords.addAll(duplicates);        
        
        // please note we cannot add more than 10 different sObject types to our deleteRecords list, as that will crash the DML delete operation
        
        // delete records
        Map<Id, DatabaseResult> databaseResults = new Map<Id, DatabaseResult>();
        List<Database.DeleteResult> deleteResults = Database.Delete(deleteRecords, false);
        
        // store results in databaseResults map
        for (Integer i = 0; i < deleteRecords.size(); i++) {
            databaseResults.put(deleteRecords[i].Id, new DatabaseResult(deleteResults[i]));
        }
        
        // delete records permanently
        if (!recycleRecords.isEmpty()) { 
            List<Database.EmptyRecycleBinResult> emptyRecycleBinResults = Database.emptyRecycleBin(recycleRecords);
            for (Integer i = 0; i < recycleRecords.size(); i++) {
                databaseResults.put(recycleRecords[i].Id, new DatabaseResult(emptyRecycleBinResults[i]));
            }
        }
        
        return databaseResults;
    }
    
    // Deletes field history for set of records and list of field names
    // NB: special delete field history permissions are needed for the profile executing this
    // NB: historyFieldNames can be different from the Salesforce API field names, please see constructor
    // for overrides
    private Map<Id, DatabaseResult> deleteHistoryRecords(List<Id> recordIDs) {
        System.debug('Deleting ' + recordIDs + ' history records from previous batch, IDs are: ' + recordIDs);

        List<sObject> deleteRecords = new List<sObject>();
        List<String> historyFieldNames = this.historyFieldNames; // because this.historyFieldNames cannot be used in dynamic queries below
        
        // get history records for relevant fields
        if (Schema.getGlobalDescribe().containsKey(this.historyObjectName)) { 
            String historyQuery = 'SELECT Field FROM ' + this.historyObjectName + ' WHERE Field IN :historyFieldNames AND ' + this.historyObjectRelationshipFieldName + ' IN :recordIDs';
    
            for (sObject record : database.query(historyQuery)) {
                deleteRecords.add( record );
            }
        }
            
        // check if field history archive is available
        Map<String, Schema.SObjectType> gd = Schema.getGlobalDescribe();
        if (gd.containsKey('FieldHistoryArchive')) {

            // add archive records to delete list
            String archiveQuery = 'SELECT Field FROM FieldHistoryArchive WHERE FIELD IN :historyFieldNames AND ParentId IN :recordIDs';

            for (sObject archive : database.query(archiveQuery)) {
                deleteRecords.add( archive );
            }
        }       
   
        // delete records
        List<Database.DeleteResult> results = Database.Delete(deleteRecords, false);
        
        Map<Id, DatabaseResult> databaseResults = new Map<Id, DatabaseResult>();
        for (Integer i = 0; i < deleteRecords.size(); i++) {
            databaseResults.put(deleteRecords[i].Id, new DatabaseResult(results[i]));
        }
        return databaseResults;
    }
    
     // send email to administrators notifying them that something went wrong with this batch job
    private void sendEmailToAdminsForFails(){
        system.debug('sendEmailToAdminsForFails');
        String emailbody = '<h1>Scheduled anonymization job for sObject: ' + this.sObjectName + ' encountered an error</h1><br/><br/>';
        emailbody += '<p>Please review the Apex Queue and EntLog log records in Salesforce.</p>';
        
        List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();

        List<String> toAddresses = new List<String>();
        List<User> users = [SELECT id, Email FROM User WHERE Profile.Name = : 'System Administrator' AND IsActive = TRUE];
        for(User u : users) { toAddresses.add(u.Email); }
        if (!toAddresses.isEmpty()) {
            mail.setToAddresses(toAddresses);
            mail.setSubject('Salesforce Anonymization Exception');
            String body = emailbody;
            mail.setHtmlBody(body);
            mails.add(mail);
            
            try { Messaging.sendEmail(mails); }
            catch(Exception ex) { System.debug(ex); }
        }
    }
    
    // in case of error with related records, use this function to find which record
    public static String findObjectNameFromRecordIdPrefix(String recordIdOrPrefix){
        String objectName = '';
        //Get prefix from record ID
        //This assumes that you have passed at least 3 characters
        String myIdPrefix = String.valueOf(recordIdOrPrefix).substring(0,3);
        
        //Get schema information
        Map<String, Schema.SObjectType> gd =  Schema.getGlobalDescribe(); 
        
        //Loop through all the sObject types returned by Schema
        for(Schema.SObjectType stype : gd.values()){
            Schema.DescribeSObjectResult r = stype.getDescribe();
            String prefix = r.getKeyPrefix();
            //System.debug('Prefix is ' + prefix);
            
            //Check if the prefix matches with requested prefix
            if(prefix!=null && prefix.equals(myIdPrefix)){
                objectName = r.getName();
                System.debug('Object Name! ' + objectName);
                break;
            }
        }
       
        //Usage: System.debug(findObjectNameFromRecordIdPrefix('0D5'));
        return objectName;
    }
    
     // store database results to ent_log records
    public static Boolean processDatabaseOperationResults(Map<Id, DatabaseResult> databaseResults) {
        Boolean hasErrors = false;

        Map<Integer, List<String>> idStrings;
        Map<Integer, String> infos;
        String info, sObjectName;
        Integer hashInfo;
        
        // combine multiple errors with the same status code, message and fields:
        idStrings = new Map<Integer, List<String>>();
        infos = new Map<Integer, String>();
        DatabaseResult result;
        for (Id id : databaseResults.keySet()) {
            result = databaseResults.get(id);
            try { sObjectName = id.getSobjectType().getDescribe().getName(); }
            catch (Exception e) { sObjectName = 'Undefined'; }
                        
            if (!result.isSuccess()) {
                for(Database.Error err : result.getErrors()) {
                    info = 'Operation: ' + result.getType() + ', Status Code: ' + err.getStatusCode() + ', Message: ' + err.getMessage() + ', sObject: ' + sObjectName + ', Fields: ' + String.join(err.getFields(), ', ');
                    hashInfo = info.hashCode();
                    if (!idStrings.containsKey(hashInfo) || idStrings.get(hashInfo) == null) {
                        idStrings.put(hashInfo, new List<String>());
                    }
                    idStrings.get(hashInfo).add(id);
                    infos.put(hashInfo, info);
                }
            }
        }
                
        String idString;
        for (Integer key: idStrings.keyset()) {
            hasErrors = true;
            System.debug('Anonymization - Database operation fails with following errors: \n' + infos.get(key) + '\n on IDs: ' + String.join(idStrings.get(key),', ') + '');
            /*EntLog_Logger.logAllException (new AnonymizationSObjectException(infos.get(key))
                , 'Anonymization - Database operation fails with following errors: \n' + infos.get(key) + '\n on IDs: ' + String.join(idStrings.get(key), ', ')
                , 'AnonymizationSObject'
                , 'processDatabaseOperationResults');*/
        }

        return hasErrors;
    }
    
     // Start method's implementation of Batch Class
    global Database.QueryLocator start(Database.BatchableContext BC) {
        return Database.getQueryLocator(this.query);
    }
    
     // loop through records, and truncate fields as specified in their anonymization field rules
    global void execute(Database.BatchableContext BC, List<sObject> records) {
        Map<Id, DatabaseResult> databaseResults = new Map<Id, DatabaseResult>();

        // delete history records created by last batch; 
        // we can't delete history records in the same transaction, as they only get created after the transaction completes
        databaseResults.putAll(deleteHistoryRecords(previousBatchRecordIDs));
        this.previousBatchRecordIDs = new List<Id>();

        List<sObject> saveRecords = new List<sObject>();
        String fieldName;
        Schema.DisplayType fieldDataType;
        Boolean randomize;
        Integer truncate;
        
        system.debug('fieldRules are ' + this.fieldRules);

        for(sObject record : records) {
            
            for(Anonymization_Field__c fieldRule : fieldRules) {
                fieldName = fieldRule.Field__c;
                fieldDataType = fieldDataTypes.get(fieldName);
                randomize = fieldRule.Randomize__c;
                truncate = Integer.valueOf(fieldRule.Truncate__c);

                doTruncation(record, fieldName, fieldDataType, randomize, truncate);
            }
            if (hasAnonymizedField) {
                record.put(AnonymizationConstants.ANONYMIZED_FIELD_NAME, true);
            }
            this.previousBatchRecordIDs.add(record.Id);
            saveRecords.add(record);
        }            
        
        system.debug('saveRecords are ' + saveRecords);
        
        // update records, and save any errors so they can later be processed into log entries        
        List<Database.SaveResult> results = Database.update(saveRecords, false);
        for (Integer i = 0; i < saveRecords.size(); i++) {
            databaseResults.put(saveRecords[i].Id, new DatabaseResult(results[i]));
        }

        databaseResults.putAll(deleteChildRecords(records));

        this.hasDMLErrors |= processDatabaseOperationResults(databaseResults);
    }
    
    // Finish method's implementation of Batch Class
    global void finish(Database.BatchableContext bc) {
        // process history records from final batch
        Map<Id, DatabaseResult> databaseResults = deleteHistoryRecords(previousBatchRecordIDs);
        this.hasDMLErrors |= processDatabaseOperationResults(databaseResults);
        
        AsyncApexJob a = [Select Id, Status, NumberOfErrors, JobItemsProcessed, TotalJobItems, ExtendedStatus from AsyncApexJob where Id = :bc.getJobId()];
        System.debug('Apex job result: ' + a);
                
        if (this.hasDMLErrors || a.Status.toLowerCase().equals('failed') || a.Status.toLowerCase().equals('aborted') || !String.isBlank(a.ExtendedStatus) || a.NumberOfErrors > 0 || Test.isRunningTest()) {
            sendEmailToAdminsForFails();
            AnonymizationJobs.setAnonymizationJobStatus(this.sObjectName, AnonymizationConstants.ANONYMIZATION_JOB_STATUS_ERROR);
        } else {
            AnonymizationJobs.setAnonymizationJobStatus(this.sObjectName, AnonymizationConstants.ANONYMIZATION_JOB_STATUS_DONE);
        }
    }
}