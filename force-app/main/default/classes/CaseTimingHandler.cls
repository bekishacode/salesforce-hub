public with sharing class CaseTimingHandler {
    public static Boolean isFirstRun = true;
    private static final String STATUS_IN_PROGRESS = 'In Progress';
    
    public static void handleOwnerAndStatusChanges(List<Case> newCases, Map<Id, Case> oldCasesMap) {
        if (!isFirstRun) return;
        isFirstRun = false;
        
        List<Case> casesToUpdate = new List<Case>();
        DateTime now = DateTime.now();
        
        for (Case newCase : newCases) {
            Case oldCase = oldCasesMap.get(newCase.Id);
            
            if (isAcceptedByAgent(oldCase, newCase)) {
                casesToUpdate.add(new Case(
                    Id = newCase.Id,
                    DateTimeAccepted__c = now,
                    Status = STATUS_IN_PROGRESS
                ));
            }
            
            if (isCaseResolved(oldCase, newCase)) {
                casesToUpdate.add(new Case(
                    Id = newCase.Id,
                    DateTimeResolved__c = now
                ));
            }
        }
        
        if (!casesToUpdate.isEmpty()) {
            update casesToUpdate;
        }
    }
    
    private static Boolean isAcceptedByAgent(Case oldCase, Case newCase) {
        if (oldCase == null || newCase.OwnerId == oldCase.OwnerId) {
            return false;
        }
        
        String oldOwnerId = String.valueOf(oldCase.OwnerId);
        String newOwnerId = String.valueOf(newCase.OwnerId);
        
        return oldOwnerId.startsWith('00G') && newOwnerId.startsWith('005');
    }
    
    private static Boolean isCaseResolved(Case oldCase, Case newCase) {
        if (oldCase == null) return false;
        return !oldCase.IsClosed && newCase.IsClosed;
    }
}