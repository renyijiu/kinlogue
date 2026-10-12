#include "KinlogueSQLiteConfiguration.h"

int kinlogue_sqlite_configuration(sqlite3 *database, int *defensive, int *extensions) {
    int result = sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, -1, defensive);
    if (result != SQLITE_OK) return result;
    if (sqlite3_compileoption_used("OMIT_LOAD_EXTENSION")) {
        *extensions = 0;
        return SQLITE_OK;
    }
    return sqlite3_db_config(database, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, -1, extensions);
}

int kinlogue_sqlite_configure(sqlite3 *database) {
    int result = sqlite3_db_config(database, SQLITE_DBCONFIG_DEFENSIVE, 1, 0);
    if (result != SQLITE_OK) return result;
    if (!sqlite3_compileoption_used("OMIT_LOAD_EXTENSION")) {
        result = sqlite3_db_config(database, SQLITE_DBCONFIG_ENABLE_LOAD_EXTENSION, 0, 0);
        if (result != SQLITE_OK) return result;
    }
    int defensive = 0, extensions = 1;
    result = kinlogue_sqlite_configuration(database, &defensive, &extensions);
    if (result != SQLITE_OK) return result;
    if (defensive != 1 || extensions != 0) return SQLITE_ERROR;
    sqlite3_limit(database, SQLITE_LIMIT_LENGTH, 32 * 1024 * 1024);
    sqlite3_limit(database, SQLITE_LIMIT_SQL_LENGTH, 1024 * 1024);
    sqlite3_limit(database, SQLITE_LIMIT_ATTACHED, 0);
    return SQLITE_OK;
}
