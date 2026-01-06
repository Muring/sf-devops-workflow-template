public with sharing class CiCdSampleService {
    /**
     * 문자열을 정리합니다.
     * - null이면 빈 문자열 반환
     * - 앞뒤 공백 제거
     */
    public static String normalize(String input) {
        return input == null ? '' : input.trim();
    }

    /**
     * 오늘 날짜(Org 타임존 기준)의 ISO 문자열(YYYY-MM-DD)을 반환합니다.
     * 테스트에서 deterministic 하게 검증 가능
     */
    public static String todayIso() {
        Date d = Date.today();
        return String.valueOf(d); // Date.toString()은 YYYY-MM-DD
    }

    /**
     * (배포/CRUD 테스트용) Account Name을 normalize해서 업데이트합니다.
     * - accountId가 null이면 예외
     * - record가 없으면 예외
     */
    public static void updateAccountName(Id accountId, String newName) {
        if (accountId == null) {
            throw new AuraHandledException('accountId is required.');
        }

        Account a = [
            SELECT Id, Name
            FROM Account
            WHERE Id = :accountId
            LIMIT 1
        ];

        a.Name = normalize(newName);
        update a;
    }
}
