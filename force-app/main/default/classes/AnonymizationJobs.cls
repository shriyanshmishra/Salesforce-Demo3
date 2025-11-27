/*=====================================================================================
*
* @purpose: sets up the records that require anonymization, and ships them off to the field batch updater
*
* @author:  Nitesh Mali (Sisodia) : nitesh.mali@oaknorth.com
*           Leo Pape : leo.pape@oaknorth.com

* @history:
* version                   | author                       | changes
* ====================================================================================
* 1.0 (27.10.2017)          | nitesh.mali@oaknorth.com     | initial version
* 2.0 (01.03.2018)          | leo.pape@oaknorth.com        | further enhancements
* 
*/

// Testing the DevOps

public class AnonymizationJobs {
    private class AnonymizationJobsException extends Exception {}
    private Map<String, String> sObjectWhereClauses; // maps object api names to where clauses in Anonymization sObject settings
    private Map<String, Anonymization_Sobject__c> sObjectSettings; // map of object name to Object Anonymization settings
    private final Boolean anonymizeAll, skipAnonymizedRecords;
    
    // this methods return type of Organization ie. Sandbox = True or False
    private static Boolean runningInASandbox() {
        return [SELECT IsSandbox FROM Organization LIMIT 1].IsSandbox;
    }
    
    // return the count of currently running batch jobs
    private static Integer currentRunningBatchJobs() {
        List<AsyncApexJob> jobs = [SELECT Id FROM AsyncApexJob 
                                    WHERE (Status = 'Queued' OR Status = 'Processing' OR Status = 'Holding') and JobType = 'BatchApex'];
        return jobs.size();
    }
    
    // check if a field exists on an sObject
    private static Boolean sObjectHasField(String sObjectName, String fieldName) {
        for(Schema.DescribeSobjectResult res : Schema.describeSObjects(new String[] {sObjectName})) {
            return res.fields.getMap().containsKey(fieldName);
        }
        return false;
    }    

    // sets Anonymization Job status, inserts new record if not yet exists
    public static void setAnonymizationJobStatus(String sObjectName, String status) {
        // replace double underscores
        String name = sObjectName.left(38);
        name.replace('__', '_'); // record name can't have double underscores
        List<Anonymization_Job__c> jobs = new List<Anonymization_Job__c> {new Anonymization_Job__c(Name = name, sObject_Name__c = sObjectName, Status__c = status)};
        upsert jobs sObject_Name__c;
    }

    // sets empty status for all Anonymization Jobs
    public static void resetAnonymizationJobStatus() {
        List<Anonymization_Job__c> jobs = [SELECT Id, Status__c FROM Anonymization_Job__c];
        for (Anonymization_Job__c job : jobs) {
            job.Status__c = '';
        }
        update jobs;
    }

    // set of sObject names for which the job is in progress since the last X hours
    private String getNextSObjectName() {
        Set<String> inProgressOrCompleteJobs = new Set<String>();
        for (Anonymization_Job__c inProgressOrComplete:
            [SELECT Id, sObject_Name__c, Status__c FROM Anonymization_Job__c WHERE
                Status__c IN (:AnonymizationConstants.ANONYMIZATION_JOB_STATUS_ERROR, :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_DONE, :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_SKIPPED)
                OR (Status__c = :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_IN_PROGRESS AND LastModifiedDate > :System.now().addHours(-AnonymizationConstants.ANONYMIZATION_JOB_TIMOUT_HOURS))
            ]) {
            inProgressOrCompleteJobs.add(inProgressOrComplete.sObject_Name__c);
        }
        Set<String> notStartedJobs = new Set<String>(sObjectSettings.keySet());
        notStartedJobs.removeAll(inProgressOrCompleteJobs);
        
        for (String sObjectName : notStartedJobs) {
            return sObjectName;
        }
        
        return null;
    }

    // set of sObject Names for which the job is complete (done or error status), or in progress for more than timeout hours
    private Set<String> getNotCompletedJobs() {
        Set<String> completedJobs = new Set<String>();
        for (Anonymization_Job__c completed : 
            [SELECT Id, sObject_Name__c FROM Anonymization_Job__c WHERE
                Status__c IN (:AnonymizationConstants.ANONYMIZATION_JOB_STATUS_ERROR, :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_DONE, :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_SKIPPED)
                OR (Status__c = :AnonymizationConstants.ANONYMIZATION_JOB_STATUS_IN_PROGRESS AND LastModifiedDate <= :System.now().addHours(-AnonymizationConstants.ANONYMIZATION_JOB_TIMOUT_HOURS))
            ]) {
            completedJobs.add(completed.sObject_Name__c);
        }

        Set<String> notCompletedJobs = new Set<String>(sObjectSettings.keySet());
        notCompletedJobs.removeAll(completedJobs);
        return notCompletedJobs;
    }

    // resolves 'where clause' placeholder paths in the list of Anonymization Object rules
    private String resolvePlaceholders(String inp) {
        Integer startTag, endTag;
        String match, replClause;
        startTag = inp.indexOf('{{');
    
        while (startTag > -1) {
            endTag = inp.indexOf('}}');
            if (endTag > -1) { 
                match = inp.subString(startTag + 2, endTag);
                if (match != null) {
                    replClause = sObjectWhereClauses.get(match);
                    if (replClause != null) {
                        //if (replClause.indexOf(' ') > -1) {
                        //    throw new AnonymizationJobsException('Encountered spaces while resolving where clause for Object ' + match + '; white-space characters (including newlines) are not allowed in referenced clauses, as they are not correctly resolved to a valid WHERE clause.');
                        //}
                        inp = inp.subString(0, startTag) + replClause + inp.subString(endTag + 2, inp.length()); // replace matching query into original input
                    } else {
                        throw new AnonymizationJobsException('No Anonymization Object metadata record found for object with API name: ' + match);
                    }
                }
            } else {
                throw new AnonymizationJobsException('Encountered unmatched {{ }} tags while resolving where clause');
            }
          
            startTag = inp.indexOf('{{', startTag); // continue search from startTag
        }
        
        return inp;
    }
    
    
    /*******************************************************************************
    @author:        Leo Pape
    @date:          01 March 2018
    @description:   Constructors for AnonymizationJobs
    *******************************************************************************/
    public AnonymizationJobs() { this(true, false); }
    public AnonymizationJobs(Boolean skipAnonymizedRecords) { this(skipAnonymizedRecords, false); }
    
    public AnonymizationJobs(Boolean skipAnonymizedRecords, Boolean anonymizeAllInSandbox) {
        this.anonymizeAll = runningInASandbox() && anonymizeAllInSandbox; // full anonymization can only be run in a Sandbox
        this.skipAnonymizedRecords = skipAnonymizedRecords;
        List<Anonymization_sObject__c> objects = [SELECT sObject_Name__c, Batch_Size__c, Where_Clause__c 
            FROM Anonymization_sObject__c WHERE Active__c = TRUE 
            ORDER BY Order_By__c ASC NULLS FIRST]; // order by lastmodified date to give a bit of flexibility to spread with conflicting record updates (lock row errors)
        this.sObjectWhereClauses = new Map<String,String>();
        this.sObjectSettings = new Map<String, Anonymization_sObject__c>();
         
        for (Anonymization_sObject__c obj : objects) {
            this.sObjectWhereClauses.put(obj.sObject_Name__c, obj.Where_Clause__c);
            this.sObjectSettings.put(obj.sObject_Name__c, obj);
        }
    }
    
    public boolean anonymizeSOBject(String sObjectName) {
        Anonymization_sObject__c thisObjectSettings = sObjectSettings.get(sObjectName);
        Integer batchSize = (Integer) thisObjectSettings.Batch_Size__c; 
        batchSize = (batchSize == null) ? AnonymizationConstants.SALESFORCE_DEFAULT_MAX_BATCH_SIZE : batchSize; 
        Boolean hasAnonymizedField = sObjectHasField(sObjectName, AnonymizationConstants.ANONYMIZED_FIELD_NAME);
        
        // construct where clause
        String collapsedWhereClause = thisObjectSettings.Where_Clause__c;
        List<String> whereClauses = new List<String>();
        if (this.anonymizeAll && AnonymizationConstants.SKIP_ANONYMIZE_ALL.contains(sObjectName.toLowerCase())) {
            System.debug('Skipping sObject: ' + sObjectName + ' for anonymizeAll');
            return false;
        }
        if (hasAnonymizedField && this.skipAnonymizedRecords) { whereClauses.add(AnonymizationConstants.ANONYMIZED_FIELD_NAME + ' = FALSE'); }
        if (!this.anonymizeAll && String.isBlank(collapsedWhereClause)) {
            throw new AnonymizationJobsException('Where clause is mandatory to prevent full anonymization of sObject: ' + sObjectName);
        }
        if (Pattern.matches('(?i).*\\sOR\\s.*', collapsedWhereClause) && (!collapsedWhereClause.startsWith('(') || !collapsedWhereClause.endsWith(')'))) {
            throw new AnonymizationJobsException('Queries containing OR clauses must be surrounded with parentheses for sObject: ' + sObjectName);
        }

        if (!this.anonymizeAll) { whereClauses.add(resolvePlaceholders(collapsedWhereClause)); }
        String fullWhereClause = String.join(whereClauses, ' AND ');
        fullWhereClause = (String.isBlank(fullWhereClause)) ? '' : ' WHERE ' + fullWhereClause;
        
        // process
        Database.executeBatch(new AnonymizationSObject(sObjectName, fullWhereClause, hasAnonymizedField), batchSize);
        return true;
    }    
    
    public boolean AnonymizeOrphans(String sObjectName) {
        Anonymization_sObject__c thisObjectSettings = sObjectSettings.get(sObjectName);
        Integer batchSize = (Integer) thisObjectSettings.Batch_Size__c; 
        batchSize = (batchSize == null) ? AnonymizationConstants.SALESFORCE_DEFAULT_MAX_BATCH_SIZE : batchSize; 
        //String orphanAction = thisObjectSettings.Orphan_Action__c;
        //String orphanClause = thisObjectSettings.Orphan_Clause__c;
       
        // process
        /*if (!String.isBlank(orphanClause)) {
            List<String> whereClauses = new List<String>();
            whereClauses.add(orphanClause);
            whereClauses.add('CreatedDate < LAST_N_DAYS:' + AnonymizationConstants.ORPHAN_WAIT_NUMBER_DAYS);
            Database.executeBatch(new AnonymizationOrphans(sObjectName, String.join(whereClauses, ' AND '), orphanAction), batchSize);
            return true;
        }*/
        return false;
    }
    
    // main control loop for scheduling the Object Anonymization Jobs
    public Boolean enqueueJobs() {

        // return the sObject name for the next scheduled Anonymization Job
        // we schedule one job per sObject, and keep track which sObjects have been processed
        Set<String> notCompletedJobs = getNotCompletedJobs();
        
        if (notCompletedJobs.isEmpty()) {
            System.debug('All anonymization jobs are completed. Clearing all statuses and starting from scratch.');
            resetAnonymizationJobStatus();
        } 

        String sObjectName = getNextSObjectName();
        if (sObjectName == null) {
            System.debug('Existing anonymization job in progress, no new jobs to be started, returning without scheduling new jobs.');
            return true;
        } else {
            System.debug('Starting anonymization job from sObject: ' + sObjectName);
        }

        Integer batchCounter = currentRunningBatchJobs(); // check how many batch jobs are running
        while (sObjectName != null && batchCounter < AnonymizationConstants.BATCH_JOB_LIMIT) {
            System.debug('Processing Anonymization Job for Object: ' + sObjectName);
            if (anonymizeSOBject(sObjectName)) {
                setAnonymizationJobStatus(sObjectName, AnonymizationConstants.ANONYMIZATION_JOB_STATUS_IN_PROGRESS);
                batchCounter++;
            } else {
                setAnonymizationJobStatus(sObjectName, AnonymizationConstants.ANONYMIZATION_JOB_STATUS_SKIPPED);
            }

            if (anonymizeOrphans(sObjectName)) {
                batchCounter++;
            }

            //batchCounter = currentRunningBatchJobs(); // update number of running batch jobs
            sObjectName = getNextSObjectName(); // check if there are any next jobs
        }
        
        // check if there are stil any sObjects left to process
        if (sObjectName == null) { 
            System.debug('All sObject Anonymization Jobs finisehd.');
            return true;
        } else {
            System.debug('Unable to process all sObject Anonymization jobs, next sObject is: ' + sObjectName);
            return false;
        }
    }
}