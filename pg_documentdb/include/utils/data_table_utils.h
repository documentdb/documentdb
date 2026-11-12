/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.
 * Licensed under the MIT License
 *
 * include/utils/data_table_utils.h
 *
 * Utilities for mongo feature usage tracking.
 *
 *-------------------------------------------------------------------------
 */

 #ifndef DATA_TABLE_UTILS_H
 #define DATA_TABLE_UTILS_H

ArrayType * GetCollectionIds(void);
ArrayType * GetCollectionIdsStartingFrom(uint64 startCollectionId, int limit);
void AlterCreationTime(void);
void AlterRolesTablePrimaryKey(void);
void CreateValidateDbNameTrigger(void);


#endif /* DATA_TABLE_UTILS_H */
