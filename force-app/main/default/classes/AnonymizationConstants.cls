/*=====================================================================================
*
* @purpose: This class contains the constants used in Anonymization
*
* @author:  Nitesh Mali (Sisodia) : nitesh.mali@oaknorth.com

* @history:
* version                   | author                       | changes
* ====================================================================================
* 1.0 (27.10.2017)          | nitesh.mali@oaknorth.com     | initial version
*/

public class AnonymizationConstants {
    public static final Integer[] ALPHA_NUMERICS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefghijklmnopqrstuvwxyz'.getChars();
    public static final Integer[] ALPHABETICS = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'.getChars();
    public static final Integer[] NUMERICS = '0123456789'.getChars();
    public static final Integer[] ZERO = '0'.getChars();
    public static final Integer[] NUMERICS_SEPARATORS = '.,'.getChars();
    public static final Integer[] EMAIL_SEPARATORS = '.@'.getChars();
    public static final Integer[] URL_SEPARATORS = ':/.?&-'.getChars();
    public static final String LOWEST_DATE_STRING = '1700-01-01 10:10:10';
    public static final String LOWEST_DATETIME_STRING = '1700-01-01 10:10:10';
    public static final Integer BATCH_JOB_LIMIT = 5;
    public static final Integer SALESFORCE_DEFAULT_MAX_BATCH_SIZE = 200;
    
    public static final Set<String> ALWAYS_REQUIRE_WHERE_CLAUSE_SOBJECTS = new Set<String> { 'User' };
    public static final Set<String> SKIP_ANONYMIZE_ALL = new Set<String> { 'User'.toLowerCase() };
        
    public static final Integer ORPHAN_WAIT_NUMBER_DAYS = 30; // the number of days to wait after record creation until executing the orphan actions
    
    public static final Integer QUEUE_FILLER_CHECK_INTERVAL_MINUTES = 1; // the frequency of running the queue filler
    
    public static final Integer ANONYMIZATION_JOB_TIMOUT_HOURS = 2; // scheduled anonymization jobs are considered failed if they haven't completed after this number of hours
    public static final String ANONYMIZATION_JOB_STATUS_IN_PROGRESS = 'In Progress';
    public static final String ANONYMIZATION_JOB_STATUS_ERROR = 'Exception';
    public static final String ANONYMIZATION_JOB_STATUS_DONE = 'Done';
    public static final String ANONYMIZATION_JOB_STATUS_SKIPPED = 'Skipped';
    
    public static final String ANONYMIZED_FIELD_NAME = 'Anonymized__c';
    
    // list of PARENT OBJECTS for objects that are difficult to handle in the nCino data model, and require special handling code
    public static final Set<String> TRICKY_NCINO_RECORD_TRIGGERS = new Set<String> { 
       'LLC_BI__AccountDocument__c'.toLowerCase()
     , 'LLC_BI__LLC_LoanDocument__c'.toLowerCase()
     , 'LLC_BI__Document_Placeholder__c'.toLowerCase()
     , 'LLC_BI__ClosingDocument__c'.toLowerCase()
     , 'LLC_BI__Loan__c'.toLowerCase()
     , 'LLC_BI__Product_Package__c'.toLowerCase()
     , 'LLC_BI__Treasury_Service__c'.toLowerCase()
     , 'LLC_BI__Review__c'.toLowerCase()};

}