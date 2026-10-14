#ifndef KINLOGUE_SQLITE_CONFIGURATION_H
#define KINLOGUE_SQLITE_CONFIGURATION_H
#include <sqlite3.h>
int kinlogue_sqlite_configure(sqlite3 *database);
int kinlogue_sqlite_configuration(sqlite3 *database, int *defensive, int *extensions);
#endif
