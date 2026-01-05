public with sharing class test {
    public test() {
        for (Account acc : accList) { Account ACC = [SELECT Id FROM Account WHERE Id = acc.Id];}
    }
}