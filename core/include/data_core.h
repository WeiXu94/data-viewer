#ifndef DATA_CORE_H
#define DATA_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DataDoc DataDoc;

typedef enum {
    DATA_NUMERIC,
    DATA_STRING
} DataColType;

typedef enum {
    DATA_FILE_STATA,
    DATA_FILE_RDS,
    DATA_FILE_MAT
} DataFileType;

typedef struct {
    int32_t index;
    char *name;
    char *label;
    DataColType type;
    char *format;
} DataColumn;

typedef struct {
    int64_t row_count;
    int32_t col_count;
    DataColumn *columns;
    char *dataset_label;
    DataFileType file_type;
} DataMeta;

typedef struct {
    int64_t offset;
    int32_t count;
    int32_t col_count;
    char **cells;
} DataChunk;

typedef struct {
    int64_t hits;
    int64_t misses;
    int32_t cached_chunks;
    int32_t chunk_size;
} DataCacheStats;

enum {
    DATA_CORE_OK = 0,
    DATA_CORE_ERROR_ALLOC = -1000,
    DATA_CORE_ERROR_BAD_ARGUMENT = -1001,
    DATA_CORE_ERROR_OVERFLOW = -1002,
    DATA_CORE_ERROR_UNSUPPORTED_FORMAT = -1003,
    DATA_CORE_ERROR_UNSUPPORTED_DATA = -1004,
    DATA_CORE_ERROR_PARSE = -1005,
    DATA_CORE_ERROR_UNSUPPORTED_COMPRESSION = -1006
};

DataDoc *data_open(const char *path, int *out_err);
const DataMeta *data_metadata(DataDoc *doc);
DataChunk *data_fetch(DataDoc *doc, int64_t offset, int32_t count);
void data_chunk_free(DataChunk *chunk);
void data_close(DataDoc *doc);

int data_last_error(DataDoc *doc);
DataCacheStats data_cache_stats(DataDoc *doc);
const char *data_error_message(int code);

#ifdef __cplusplus
}
#endif

#endif
