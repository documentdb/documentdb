/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * include/users.h
 *
 * User CRUD functions.
 *
 *-------------------------------------------------------------------------
 */

#ifndef EXTENSION_USERS_H
#define EXTENSION_USERS_H

#include "postgres.h"
#include "utils/string_view.h"

/* Method to call Connection Status command */
Datum connection_status(pgbson *showPrivilegesSpec);

#endif
