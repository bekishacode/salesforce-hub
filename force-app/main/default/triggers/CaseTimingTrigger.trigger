trigger CaseTimingTrigger on Case (after update) {
    if (CaseTimingHandler.isFirstRun) {
        CaseTimingHandler.handleOwnerAndStatusChanges(Trigger.new, Trigger.oldMap);
    }
}