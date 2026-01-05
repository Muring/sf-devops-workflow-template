public with sharing class test {
    public test() {
        List<Account> accList = new List<Account>();

        for (Account acc : accList) { Account ACC = [SELECT Id FROM Account WHERE Id = acc.Id];}
    }
}