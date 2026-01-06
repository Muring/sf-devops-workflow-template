@IsTest
private class CiCdSampleServiceTest {
    @IsTest
    static void normalizeNullReturnsEmpty() {
        String result = CiCdSampleService.normalize(null);
        System.assertEquals('', result);
    }

    @IsTest
    static void normalizeTrimsWhitespace() {
        String result = CiCdSampleService.normalize('  Hello  ');
        System.assertEquals('Hello', result);
    }

    @IsTest
    static void todayIsoReturnsTodayInIsoFormat() {
        String result = CiCdSampleService.todayIso();
        System.assertEquals(String.valueOf(Date.today()), result);
    }

    @IsTest
    static void updateAccountNameUpdatesNameWithNormalizedValue() {
        Account a = new Account(Name = 'Before');
        insert a;

        Test.startTest();
        CiCdSampleService.updateAccountName(a.Id, '  After  ');
        Test.stopTest();

        Account reloaded = [SELECT Name FROM Account WHERE Id = :a.Id];
        System.assertEquals('After', reloaded.Name);
    }

    @IsTest
    static void updateAccountNameNullIdThrows() {
        try {
            CiCdSampleService.updateAccountName(null, 'X');
            System.assert(false, 'Expected exception was not thrown.');
        } catch (Exception e) {
            System.assert(
                e.getMessage().contains('accountId is required.'),
                'Unexpected message: ' + e.getMessage()
            );
        }
    }
}
