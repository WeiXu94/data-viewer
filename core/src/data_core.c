#include "data_core.h"

#include "../readstat/src/readstat.h"
#include "matio.h"
#include "rdata.h"

#include <ctype.h>
#include <limits.h>
#include <math.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DATA_CHUNK_SIZE 1000
#define DATA_CACHE_CAPACITY 12

typedef struct {
    int in_use;
    int64_t offset;
    int32_t count;
    char **cells;
    uint64_t last_used;
} DataCacheEntry;

typedef enum {
    DATA_STORAGE_STATA,
    DATA_STORAGE_MEMORY
} DataStorage;

struct DataDoc {
    char *path;
    DataStorage storage;
    DataMeta meta;
    char **memory_cells;
    DataCacheEntry cache[DATA_CACHE_CAPACITY];
    uint64_t cache_clock;
    int64_t cache_hits;
    int64_t cache_misses;
    int last_error;
    pthread_mutex_t lock;
};

typedef struct {
    DataDoc *doc;
    int error;
} DataMetaParseCtx;

typedef struct {
    DataDoc *doc;
    DataChunk *chunk;
    int error;
} DataFetchCtx;

typedef struct {
    DataDoc *doc;
    int active_text_column;
    int error;
} DataRdsParseCtx;

typedef struct {
    char *name;
    int is_vector;
    int is_logical;
    enum matio_types data_type;
    enum matio_classes class_type;
    size_t rows;
    size_t cols;
    size_t length;
} DataMatCandidate;

typedef struct {
    DataMatCandidate *items;
    int count;
    int capacity;
} DataMatCandidateList;

static char *data_strdup(const char *s) {
    const char *value = s ? s : "";
    size_t len = strlen(value);
    char *copy = malloc(len + 1);
    if (!copy)
        return NULL;
    memcpy(copy, value, len + 1);
    return copy;
}

static void data_free_columns(DataMeta *meta) {
    if (!meta)
        return;
    if (meta->columns) {
        for (int32_t i = 0; i < meta->col_count; i++) {
            free(meta->columns[i].name);
            free(meta->columns[i].label);
            free(meta->columns[i].format);
        }
        free(meta->columns);
    }
    free(meta->dataset_label);
    memset(meta, 0, sizeof(*meta));
}

static int data_cell_total_fits64(int64_t row_count, int32_t col_count, size_t *out_total) {
    if (row_count < 0 || col_count < 0)
        return 0;
    if (col_count != 0 && (uint64_t)row_count > SIZE_MAX / (uint64_t)col_count)
        return 0;
    *out_total = (size_t)row_count * (size_t)col_count;
    return 1;
}

static int data_cell_total_fits(int32_t count, int32_t col_count, size_t *out_total) {
    if (count < 0 || col_count < 0)
        return 0;
    if (col_count != 0 && (size_t)count > SIZE_MAX / (size_t)col_count)
        return 0;
    *out_total = (size_t)count * (size_t)col_count;
    return 1;
}

static void data_memory_cells_free(char **cells, int64_t row_count, int32_t col_count) {
    size_t total = 0;
    if (!cells)
        return;
    if (data_cell_total_fits64(row_count, col_count, &total)) {
        for (size_t i = 0; i < total; i++)
            free(cells[i]);
    }
    free(cells);
}

static int data_doc_add_column(DataDoc *doc, const char *name, const char *label,
        DataColType type, const char *format, int64_t row_count) {
    if (!doc || row_count < 0 || doc->meta.col_count == INT32_MAX)
        return 0;
    if (doc->meta.col_count > 0 && doc->meta.row_count != row_count)
        return 0;

    int32_t old_col_count = doc->meta.col_count;
    int32_t new_col_count = old_col_count + 1;
    size_t new_total = 0;
    char **new_cells = NULL;

    if (doc->storage == DATA_STORAGE_MEMORY) {
        if (!data_cell_total_fits64(row_count, new_col_count, &new_total))
            return 0;
        if (new_total > 0) {
            new_cells = calloc(new_total, sizeof(char *));
            if (!new_cells)
                return 0;
            for (int64_t row = 0; row < row_count; row++) {
                for (int32_t col = 0; col < old_col_count; col++) {
                    size_t old_index = (size_t)row * (size_t)old_col_count + (size_t)col;
                    size_t new_index = (size_t)row * (size_t)new_col_count + (size_t)col;
                    new_cells[new_index] = doc->memory_cells[old_index];
                }
            }
        }
    }

    char *name_copy = data_strdup(name);
    char *label_copy = data_strdup(label);
    char *format_copy = data_strdup(format);
    if (!name_copy || !label_copy || !format_copy) {
        free(name_copy);
        free(label_copy);
        free(format_copy);
        free(new_cells);
        return 0;
    }

    DataColumn *columns = realloc(doc->meta.columns, (size_t)new_col_count * sizeof(DataColumn));
    if (!columns) {
        free(name_copy);
        free(label_copy);
        free(format_copy);
        free(new_cells);
        return 0;
    }

    if (doc->storage == DATA_STORAGE_MEMORY) {
        free(doc->memory_cells);
        doc->memory_cells = new_cells;
    }

    doc->meta.columns = columns;
    doc->meta.row_count = row_count;
    doc->meta.col_count = new_col_count;
    DataColumn *column = &doc->meta.columns[old_col_count];
    column->index = old_col_count;
    column->name = name_copy;
    column->label = label_copy;
    column->type = type;
    column->format = format_copy;
    return 1;
}

static int data_doc_set_column_name(DataDoc *doc, int32_t index, const char *name) {
    if (!doc || index < 0 || index >= doc->meta.col_count)
        return 0;
    char *copy = data_strdup(name);
    if (!copy)
        return 0;
    free(doc->meta.columns[index].name);
    doc->meta.columns[index].name = copy;
    return 1;
}

static int data_doc_set_cell_take(DataDoc *doc, int64_t row, int32_t col, char *value) {
    if (!doc || doc->storage != DATA_STORAGE_MEMORY || row < 0 || col < 0 ||
            row >= doc->meta.row_count || col >= doc->meta.col_count) {
        free(value);
        return 0;
    }
    size_t total = 0;
    if (!data_cell_total_fits64(doc->meta.row_count, doc->meta.col_count, &total)) {
        free(value);
        return 0;
    }
    size_t index = (size_t)row * (size_t)doc->meta.col_count + (size_t)col;
    if (index >= total) {
        free(value);
        return 0;
    }
    free(doc->memory_cells[index]);
    doc->memory_cells[index] = value;
    return 1;
}

static const char *data_path_extension(const char *path) {
    const char *last_dot = strrchr(path, '.');
    const char *last_slash = strrchr(path, '/');
    if (!last_dot || (last_slash && last_dot < last_slash))
        return "";
    return last_dot + 1;
}

static int data_extension_is(const char *path, const char *extension) {
    const char *actual = data_path_extension(path);
    while (*actual && *extension) {
        if (tolower((unsigned char)*actual) != tolower((unsigned char)*extension))
            return 0;
        actual++;
        extension++;
    }
    return *actual == '\0' && *extension == '\0';
}

static char *data_format_plain_double(double value) {
    char buffer[96];
    if (isnan(value))
        snprintf(buffer, sizeof(buffer), "NaN");
    else if (isinf(value))
        snprintf(buffer, sizeof(buffer), value < 0 ? "-Inf" : "Inf");
    else
        snprintf(buffer, sizeof(buffer), "%.15g", value);
    return data_strdup(buffer);
}

static char *data_format_signed_long_long(long long value) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%lld", value);
    return data_strdup(buffer);
}

static char *data_format_unsigned_long_long(unsigned long long value) {
    char buffer[64];
    snprintf(buffer, sizeof(buffer), "%llu", value);
    return data_strdup(buffer);
}

static char *data_format_epoch_seconds(double seconds, const char *format) {
    if (isnan(seconds))
        return NULL;
    time_t value = (time_t)seconds;
    struct tm tm_value;
    if (!gmtime_r(&value, &tm_value))
        return data_format_plain_double(seconds);
    char buffer[64];
    if (strftime(buffer, sizeof(buffer), format, &tm_value) == 0)
        return data_format_plain_double(seconds);
    return data_strdup(buffer);
}

static DataChunk *data_chunk_alloc(int64_t offset, int32_t count, int32_t col_count) {
    size_t total = 0;
    if (!data_cell_total_fits(count, col_count, &total))
        return NULL;

    DataChunk *chunk = calloc(1, sizeof(*chunk));
    if (!chunk)
        return NULL;

    chunk->offset = offset;
    chunk->count = count;
    chunk->col_count = col_count;
    if (total > 0) {
        chunk->cells = calloc(total, sizeof(char *));
        if (!chunk->cells) {
            free(chunk);
            return NULL;
        }
    }
    return chunk;
}

static void data_cells_free(char **cells, int32_t count, int32_t col_count) {
    size_t total = 0;
    if (!cells)
        return;
    if (data_cell_total_fits(count, col_count, &total)) {
        for (size_t i = 0; i < total; i++)
            free(cells[i]);
    }
    free(cells);
}

void data_chunk_free(DataChunk *chunk) {
    if (!chunk)
        return;
    data_cells_free(chunk->cells, chunk->count, chunk->col_count);
    free(chunk);
}

static int data_format_decimals(const char *format) {
    if (!format)
        return -1;
    const char *dot = strchr(format, '.');
    if (!dot)
        return -1;
    int decimals = 0;
    dot++;
    if (*dot < '0' || *dot > '9')
        return -1;
    while (*dot >= '0' && *dot <= '9') {
        decimals = decimals * 10 + (*dot - '0');
        dot++;
    }
    return decimals;
}

static int data_format_uses_commas(const char *format) {
    return format && strchr(format, 'c') != NULL;
}

static double data_numeric_as_double(readstat_value_t value) {
    switch (readstat_value_type(value)) {
        case READSTAT_TYPE_INT8:
            return readstat_int8_value(value);
        case READSTAT_TYPE_INT16:
            return readstat_int16_value(value);
        case READSTAT_TYPE_INT32:
            return readstat_int32_value(value);
        case READSTAT_TYPE_FLOAT:
            return readstat_float_value(value);
        case READSTAT_TYPE_DOUBLE:
            return readstat_double_value(value);
        default:
            return 0.0;
    }
}

static char *data_add_commas(const char *input) {
    const char *start = input;
    int negative = 0;
    if (*start == '-') {
        negative = 1;
        start++;
    }

    const char *dot = strchr(start, '.');
    size_t int_len = dot ? (size_t)(dot - start) : strlen(start);
    size_t frac_len = dot ? strlen(dot) : 0;
    if (int_len <= 3)
        return data_strdup(input);

    size_t comma_count = (int_len - 1) / 3;
    size_t out_len = (negative ? 1 : 0) + int_len + comma_count + frac_len;
    char *out = malloc(out_len + 1);
    if (!out)
        return NULL;

    char *dst = out;
    if (negative)
        *dst++ = '-';

    size_t first_group = int_len % 3;
    if (first_group == 0)
        first_group = 3;

    for (size_t i = 0; i < int_len; i++) {
        if (i > 0 && i >= first_group && (i - first_group) % 3 == 0)
            *dst++ = ',';
        *dst++ = start[i];
    }
    if (dot) {
        memcpy(dst, dot, frac_len);
        dst += frac_len;
    }
    *dst = '\0';
    return out;
}

static char *data_format_numeric(readstat_value_t value, readstat_variable_t *variable) {
    char buffer[96];
    const char *format = variable ? readstat_variable_get_format(variable) : NULL;
    int decimals = data_format_decimals(format);

    if (decimals >= 0 && decimals < 20) {
        snprintf(buffer, sizeof(buffer), "%.*f", decimals, data_numeric_as_double(value));
    } else {
        switch (readstat_value_type(value)) {
            case READSTAT_TYPE_INT8:
                snprintf(buffer, sizeof(buffer), "%d", (int)readstat_int8_value(value));
                break;
            case READSTAT_TYPE_INT16:
                snprintf(buffer, sizeof(buffer), "%d", (int)readstat_int16_value(value));
                break;
            case READSTAT_TYPE_INT32:
                snprintf(buffer, sizeof(buffer), "%d", readstat_int32_value(value));
                break;
            case READSTAT_TYPE_FLOAT:
                snprintf(buffer, sizeof(buffer), "%.9g", readstat_float_value(value));
                break;
            case READSTAT_TYPE_DOUBLE:
                snprintf(buffer, sizeof(buffer), "%.15g", readstat_double_value(value));
                break;
            default:
                buffer[0] = '\0';
                break;
        }
    }

    if (data_format_uses_commas(format))
        return data_add_commas(buffer);
    return data_strdup(buffer);
}

static char *data_format_value(readstat_value_t value, readstat_variable_t *variable) {
    if (readstat_value_type_class(value) == READSTAT_TYPE_CLASS_STRING) {
        const char *s = readstat_string_value(value);
        return s ? data_strdup(s) : NULL;
    }
    return data_format_numeric(value, variable);
}

static DataDoc *data_doc_alloc(const char *path, DataStorage storage, DataFileType file_type, int *out_err) {
    DataDoc *doc = calloc(1, sizeof(*doc));
    if (!doc) {
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    doc->path = data_strdup(path);
    if (!doc->path) {
        free(doc);
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    doc->storage = storage;
    doc->meta.file_type = file_type;
    pthread_mutex_init(&doc->lock, NULL);
    doc->last_error = DATA_CORE_OK;
    return doc;
}

static int data_rds_table_handler(const char *name, void *ctx) {
    DataRdsParseCtx *parse_ctx = ctx;
    DataDoc *doc = parse_ctx->doc;
    if (name && name[0] && !doc->meta.dataset_label) {
        doc->meta.dataset_label = data_strdup(name);
        if (!doc->meta.dataset_label) {
            parse_ctx->error = DATA_CORE_ERROR_ALLOC;
            return 1;
        }
    }
    return 0;
}

static char *data_rds_placeholder_name(int32_t index) {
    char buffer[32];
    snprintf(buffer, sizeof(buffer), "V%d", index + 1);
    return data_strdup(buffer);
}

static char *data_rds_format_data_value(rdata_type_t type, void *data, long row) {
    switch (type) {
        case RDATA_TYPE_INT32: {
            int32_t value = ((int32_t *)data)[row];
            if (value == INT32_MIN)
                return NULL;
            return data_format_signed_long_long(value);
        }
        case RDATA_TYPE_REAL: {
            double value = ((double *)data)[row];
            if (isnan(value))
                return NULL;
            return data_format_plain_double(value);
        }
        case RDATA_TYPE_LOGICAL: {
            int32_t value = ((int32_t *)data)[row];
            if (value == INT32_MIN)
                return NULL;
            return data_strdup(value ? "TRUE" : "FALSE");
        }
        case RDATA_TYPE_TIMESTAMP: {
            double value = ((double *)data)[row];
            return data_format_epoch_seconds(value, "%Y-%m-%d %H:%M:%S");
        }
        case RDATA_TYPE_DATE: {
            double value = ((double *)data)[row];
            return data_format_epoch_seconds(value * 86400.0, "%Y-%m-%d");
        }
        default:
            return NULL;
    }
}

static int data_rds_column_handler(const char *name, rdata_type_t type, void *data, long count, void *ctx) {
    DataRdsParseCtx *parse_ctx = ctx;
    DataDoc *doc = parse_ctx->doc;
    if (count < 0) {
        parse_ctx->error = DATA_CORE_ERROR_OVERFLOW;
        return 1;
    }

    int32_t column_index = doc->meta.col_count;
    char *placeholder = name && name[0] ? NULL : data_rds_placeholder_name(column_index);
    const char *column_name = name && name[0] ? name : placeholder;
    DataColType col_type = type == RDATA_TYPE_STRING ? DATA_STRING : DATA_NUMERIC;
    if (!column_name || !data_doc_add_column(doc, column_name, "", col_type, "", count)) {
        free(placeholder);
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return 1;
    }
    free(placeholder);

    parse_ctx->active_text_column = type == RDATA_TYPE_STRING ? column_index : -1;
    if (type == RDATA_TYPE_STRING || !data)
        return 0;

    for (long row = 0; row < count; row++) {
        char *value = data_rds_format_data_value(type, data, row);
        if (value && !data_doc_set_cell_take(doc, row, column_index, value)) {
            parse_ctx->error = DATA_CORE_ERROR_ALLOC;
            return 1;
        }
    }
    return 0;
}

static int data_rds_column_name_handler(const char *name, int index, void *ctx) {
    DataRdsParseCtx *parse_ctx = ctx;
    if (name && !data_doc_set_column_name(parse_ctx->doc, index, name)) {
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return 1;
    }
    return 0;
}

static int data_rds_text_value_handler(const char *value, int index, void *ctx) {
    DataRdsParseCtx *parse_ctx = ctx;
    if (parse_ctx->active_text_column < 0)
        return 0;
    char *copy = value ? data_strdup(value) : NULL;
    if (value && !copy) {
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return 1;
    }
    if (copy && !data_doc_set_cell_take(parse_ctx->doc, index, parse_ctx->active_text_column, copy)) {
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return 1;
    }
    return 0;
}

static void data_rds_error_handler(const char *error_message, void *ctx) {
    (void)error_message;
    DataRdsParseCtx *parse_ctx = ctx;
    if (parse_ctx && parse_ctx->error == DATA_CORE_OK)
        parse_ctx->error = DATA_CORE_ERROR_PARSE;
}

static DataDoc *data_open_rds(const char *path, int *out_err) {
    DataDoc *doc = data_doc_alloc(path, DATA_STORAGE_MEMORY, DATA_FILE_RDS, out_err);
    if (!doc)
        return NULL;
    doc->meta.dataset_label = data_strdup("RDS data frame");
    if (!doc->meta.dataset_label) {
        data_close(doc);
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    rdata_parser_t *parser = rdata_parser_init();
    if (!parser) {
        data_close(doc);
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DataRdsParseCtx ctx = { .doc = doc, .active_text_column = -1, .error = DATA_CORE_OK };
    rdata_set_table_handler(parser, data_rds_table_handler);
    rdata_set_column_handler(parser, data_rds_column_handler);
    rdata_set_column_name_handler(parser, data_rds_column_name_handler);
    rdata_set_text_value_handler(parser, data_rds_text_value_handler);
    rdata_set_error_handler(parser, data_rds_error_handler);

    rdata_error_t err = rdata_parse(parser, path, &ctx);
    rdata_parser_free(parser);

    if (err != RDATA_OK || ctx.error != DATA_CORE_OK || doc->meta.col_count == 0) {
        int code = ctx.error != DATA_CORE_OK ? ctx.error : DATA_CORE_ERROR_PARSE;
        if (err == RDATA_ERROR_UNSUPPORTED_COMPRESSION)
            code = DATA_CORE_ERROR_UNSUPPORTED_COMPRESSION;
        else if (doc->meta.col_count == 0)
            code = DATA_CORE_ERROR_UNSUPPORTED_DATA;
        data_close(doc);
        if (out_err)
            *out_err = code;
        return NULL;
    }

    return doc;
}

static void data_mat_candidates_free(DataMatCandidateList *list) {
    if (!list)
        return;
    for (int i = 0; i < list->count; i++)
        free(list->items[i].name);
    free(list->items);
    memset(list, 0, sizeof(*list));
}

static int data_mat_candidate_append(DataMatCandidateList *list, const DataMatCandidate *candidate) {
    if (list->count == list->capacity) {
        int new_capacity = list->capacity == 0 ? 8 : list->capacity * 2;
        DataMatCandidate *items = realloc(list->items, (size_t)new_capacity * sizeof(*items));
        if (!items)
            return 0;
        list->items = items;
        list->capacity = new_capacity;
    }
    list->items[list->count] = *candidate;
    list->items[list->count].name = data_strdup(candidate->name);
    if (!list->items[list->count].name)
        return 0;
    list->count++;
    return 1;
}

static int data_mat_is_supported_class(enum matio_classes class_type) {
    switch (class_type) {
        case MAT_C_DOUBLE:
        case MAT_C_SINGLE:
        case MAT_C_INT8:
        case MAT_C_UINT8:
        case MAT_C_INT16:
        case MAT_C_UINT16:
        case MAT_C_INT32:
        case MAT_C_UINT32:
        case MAT_C_INT64:
        case MAT_C_UINT64:
            return 1;
        default:
            return 0;
    }
}

static int data_mat_is_supported_type(enum matio_types data_type) {
    switch (data_type) {
        case MAT_T_DOUBLE:
        case MAT_T_SINGLE:
        case MAT_T_INT8:
        case MAT_T_UINT8:
        case MAT_T_INT16:
        case MAT_T_UINT16:
        case MAT_T_INT32:
        case MAT_T_UINT32:
        case MAT_T_INT64:
        case MAT_T_UINT64:
            return 1;
        default:
            return 0;
    }
}

static enum matio_types data_mat_type_for_class(enum matio_classes class_type) {
    switch (class_type) {
        case MAT_C_DOUBLE:
            return MAT_T_DOUBLE;
        case MAT_C_SINGLE:
            return MAT_T_SINGLE;
        case MAT_C_INT8:
            return MAT_T_INT8;
        case MAT_C_UINT8:
            return MAT_T_UINT8;
        case MAT_C_INT16:
            return MAT_T_INT16;
        case MAT_C_UINT16:
            return MAT_T_UINT16;
        case MAT_C_INT32:
            return MAT_T_INT32;
        case MAT_C_UINT32:
            return MAT_T_UINT32;
        case MAT_C_INT64:
            return MAT_T_INT64;
        case MAT_C_UINT64:
            return MAT_T_UINT64;
        default:
            return MAT_T_UNKNOWN;
    }
}

static int data_mat_effective_2d(const matvar_t *var, size_t *out_rows, size_t *out_cols) {
    if (!var || !var->dims || var->rank <= 0)
        return 0;
    size_t rows = var->dims[0];
    size_t cols = var->rank > 1 ? var->dims[1] : 1;
    for (int dim = 2; dim < var->rank; dim++) {
        if (var->dims[dim] != 1)
            return 0;
    }
    if (rows > (size_t)INT64_MAX || cols > (size_t)INT32_MAX)
        return 0;
    *out_rows = rows;
    *out_cols = cols;
    return 1;
}

static int data_mat_scan_candidates(mat_t *mat, DataMatCandidateList *list) {
    matvar_t *var = NULL;
    while ((var = Mat_VarReadNextInfo(mat)) != NULL) {
        size_t rows = 0;
        size_t cols = 0;
        enum matio_types data_type = var->data_type == MAT_T_UNKNOWN
            ? data_mat_type_for_class(var->class_type)
            : var->data_type;
        if (var->name && data_mat_is_supported_class(var->class_type) &&
                data_mat_is_supported_type(data_type) &&
                data_mat_effective_2d(var, &rows, &cols) && rows > 0 && cols > 0 &&
                rows <= SIZE_MAX / cols) {
            DataMatCandidate candidate = {
                .name = var->name,
                .is_vector = rows == 1 || cols == 1,
                .is_logical = var->isLogical,
                .data_type = data_type,
                .class_type = var->class_type,
                .rows = rows,
                .cols = cols,
                .length = rows * cols
            };
            if (!data_mat_candidate_append(list, &candidate)) {
                Mat_VarFree(var);
                return 0;
            }
        }
        Mat_VarFree(var);
    }
    return 1;
}

static DataMatCandidate *data_mat_first_matrix(DataMatCandidateList *list) {
    for (int i = 0; i < list->count; i++) {
        if (!list->items[i].is_vector)
            return &list->items[i];
    }
    return NULL;
}

static size_t data_mat_best_vector_length(DataMatCandidateList *list, int *out_count) {
    size_t best_length = 0;
    int best_count = 0;
    for (int i = 0; i < list->count; i++) {
        if (!list->items[i].is_vector)
            continue;
        size_t length = list->items[i].length;
        int count = 0;
        for (int j = 0; j < list->count; j++) {
            if (list->items[j].is_vector && list->items[j].length == length)
                count++;
        }
        if (count > best_count) {
            best_count = count;
            best_length = length;
        }
    }
    if (out_count)
        *out_count = best_count;
    return best_length;
}

static double data_mat_numeric_as_double(enum matio_types type, const void *data, size_t index) {
    switch (type) {
        case MAT_T_DOUBLE:
            return ((const double *)data)[index];
        case MAT_T_SINGLE:
            return ((const float *)data)[index];
        case MAT_T_INT8:
            return ((const int8_t *)data)[index];
        case MAT_T_UINT8:
            return ((const uint8_t *)data)[index];
        case MAT_T_INT16:
            return ((const int16_t *)data)[index];
        case MAT_T_UINT16:
            return ((const uint16_t *)data)[index];
        case MAT_T_INT32:
            return ((const int32_t *)data)[index];
        case MAT_T_UINT32:
            return ((const uint32_t *)data)[index];
        case MAT_T_INT64:
            return (double)((const int64_t *)data)[index];
        case MAT_T_UINT64:
            return (double)((const uint64_t *)data)[index];
        default:
            return 0.0;
    }
}

static char *data_mat_format_cell(const matvar_t *var, size_t index) {
    if (!var || !var->data)
        return NULL;

    if (var->isComplex) {
        const mat_complex_split_t *split = var->data;
        if (!split->Re || !split->Im)
            return NULL;
        double real = data_mat_numeric_as_double(var->data_type, split->Re, index);
        double imaginary = data_mat_numeric_as_double(var->data_type, split->Im, index);
        char buffer[128];
        snprintf(buffer, sizeof(buffer), "%.15g%+.15gi", real, imaginary);
        return data_strdup(buffer);
    }

    if (var->isLogical) {
        double value = data_mat_numeric_as_double(var->data_type, var->data, index);
        return data_strdup(value == 0.0 ? "FALSE" : "TRUE");
    }

    switch (var->data_type) {
        case MAT_T_INT8:
            return data_format_signed_long_long(((const int8_t *)var->data)[index]);
        case MAT_T_INT16:
            return data_format_signed_long_long(((const int16_t *)var->data)[index]);
        case MAT_T_INT32:
            return data_format_signed_long_long(((const int32_t *)var->data)[index]);
        case MAT_T_INT64:
            return data_format_signed_long_long(((const int64_t *)var->data)[index]);
        case MAT_T_UINT8:
            return data_format_unsigned_long_long(((const uint8_t *)var->data)[index]);
        case MAT_T_UINT16:
            return data_format_unsigned_long_long(((const uint16_t *)var->data)[index]);
        case MAT_T_UINT32:
            return data_format_unsigned_long_long(((const uint32_t *)var->data)[index]);
        case MAT_T_UINT64:
            return data_format_unsigned_long_long(((const uint64_t *)var->data)[index]);
        case MAT_T_SINGLE:
            return data_format_plain_double(((const float *)var->data)[index]);
        case MAT_T_DOUBLE:
            return data_format_plain_double(((const double *)var->data)[index]);
        default:
            return NULL;
    }
}

static int data_mat_fill_vector_column(DataDoc *doc, mat_t *mat, const DataMatCandidate *candidate,
        int32_t column_index) {
    matvar_t *var = Mat_VarRead(mat, candidate->name);
    if (!var)
        return 0;
    int ok = 1;
    for (size_t row = 0; row < candidate->length; row++) {
        char *value = data_mat_format_cell(var, row);
        if (value && !data_doc_set_cell_take(doc, (int64_t)row, column_index, value)) {
            ok = 0;
            break;
        }
    }
    Mat_VarFree(var);
    return ok;
}

static int data_mat_fill_matrix(DataDoc *doc, mat_t *mat, const DataMatCandidate *candidate) {
    matvar_t *var = Mat_VarRead(mat, candidate->name);
    if (!var)
        return 0;
    int ok = 1;
    for (size_t col = 0; col < candidate->cols && ok; col++) {
        for (size_t row = 0; row < candidate->rows; row++) {
            size_t source_index = row + col * candidate->rows;
            char *value = data_mat_format_cell(var, source_index);
            if (value && !data_doc_set_cell_take(doc, (int64_t)row, (int32_t)col, value)) {
                ok = 0;
                break;
            }
        }
    }
    Mat_VarFree(var);
    return ok;
}

static int data_open_mat_vectors(DataDoc *doc, mat_t *mat, DataMatCandidateList *list, size_t length) {
    for (int i = 0; i < list->count; i++) {
        DataMatCandidate *candidate = &list->items[i];
        if (!candidate->is_vector || candidate->length != length)
            continue;
        int32_t column_index = doc->meta.col_count;
        if (!data_doc_add_column(doc, candidate->name, "", DATA_NUMERIC, "", (int64_t)length))
            return 0;
        if (!data_mat_fill_vector_column(doc, mat, candidate, column_index))
            return 0;
    }
    return doc->meta.col_count > 0;
}

static int data_open_mat_matrix(DataDoc *doc, mat_t *mat, DataMatCandidate *candidate) {
    for (size_t col = 0; col < candidate->cols; col++) {
        char name_buffer[512];
        if (candidate->cols == 1)
            snprintf(name_buffer, sizeof(name_buffer), "%s", candidate->name);
        else
            snprintf(name_buffer, sizeof(name_buffer), "%s[%zu]", candidate->name, col + 1);
        if (!data_doc_add_column(doc, name_buffer, "", DATA_NUMERIC, "", (int64_t)candidate->rows))
            return 0;
    }
    return data_mat_fill_matrix(doc, mat, candidate);
}

static DataDoc *data_open_mat(const char *path, int *out_err) {
    mat_t *mat = Mat_Open(path, MAT_ACC_RDONLY);
    if (!mat) {
        if (out_err)
            *out_err = DATA_CORE_ERROR_PARSE;
        return NULL;
    }

    DataMatCandidateList candidates = {0};
    if (!data_mat_scan_candidates(mat, &candidates)) {
        data_mat_candidates_free(&candidates);
        Mat_Close(mat);
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DataDoc *doc = data_doc_alloc(path, DATA_STORAGE_MEMORY, DATA_FILE_MAT, out_err);
    if (!doc) {
        data_mat_candidates_free(&candidates);
        Mat_Close(mat);
        return NULL;
    }

    int vector_count = 0;
    size_t vector_length = data_mat_best_vector_length(&candidates, &vector_count);
    DataMatCandidate *matrix = data_mat_first_matrix(&candidates);
    int ok = 0;
    if (vector_count >= 2 || (vector_count == 1 && !matrix)) {
        doc->meta.dataset_label = data_strdup("MAT variables");
        ok = doc->meta.dataset_label && data_open_mat_vectors(doc, mat, &candidates, vector_length);
    } else if (matrix) {
        char label[512];
        snprintf(label, sizeof(label), "MAT matrix: %s", matrix->name);
        doc->meta.dataset_label = data_strdup(label);
        ok = doc->meta.dataset_label && data_open_mat_matrix(doc, mat, matrix);
    }

    data_mat_candidates_free(&candidates);
    Mat_Close(mat);

    if (!ok) {
        data_close(doc);
        if (out_err)
            *out_err = DATA_CORE_ERROR_UNSUPPORTED_DATA;
        return NULL;
    }

    return doc;
}

static int data_metadata_handler(readstat_metadata_t *metadata, void *ctx) {
    DataMetaParseCtx *parse_ctx = ctx;
    DataDoc *doc = parse_ctx->doc;
    int64_t var_count = readstat_get_var_count(metadata);

    if (var_count < 0 || var_count > INT32_MAX) {
        parse_ctx->error = DATA_CORE_ERROR_OVERFLOW;
        return READSTAT_HANDLER_ABORT;
    }

    doc->meta.row_count = readstat_get_row_count(metadata);
    doc->meta.col_count = (int32_t)var_count;
    doc->meta.dataset_label = data_strdup(readstat_get_file_label(metadata));
    if (!doc->meta.dataset_label) {
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    if (doc->meta.col_count > 0) {
        doc->meta.columns = calloc((size_t)doc->meta.col_count, sizeof(DataColumn));
        if (!doc->meta.columns) {
            parse_ctx->error = DATA_CORE_ERROR_ALLOC;
            return READSTAT_HANDLER_ABORT;
        }
    }
    return READSTAT_HANDLER_OK;
}

static int data_variable_handler(int index, readstat_variable_t *variable, const char *val_labels, void *ctx) {
    (void)index;
    (void)val_labels;

    DataMetaParseCtx *parse_ctx = ctx;
    DataDoc *doc = parse_ctx->doc;
    int var_index = readstat_variable_get_index(variable);
    if (var_index < 0 || var_index >= doc->meta.col_count)
        return READSTAT_HANDLER_OK;

    DataColumn *column = &doc->meta.columns[var_index];
    column->index = var_index;
    column->name = data_strdup(readstat_variable_get_name(variable));
    column->label = data_strdup(readstat_variable_get_label(variable));
    column->format = data_strdup(readstat_variable_get_format(variable));
    column->type = readstat_variable_get_type_class(variable) == READSTAT_TYPE_CLASS_NUMERIC
        ? DATA_NUMERIC
        : DATA_STRING;

    if (!column->name || !column->label || !column->format) {
        parse_ctx->error = DATA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    return READSTAT_HANDLER_OK;
}

static int data_value_handler(int obs_index, readstat_variable_t *variable, readstat_value_t value, void *ctx) {
    DataFetchCtx *fetch_ctx = ctx;
    DataChunk *chunk = fetch_ctx->chunk;
    int col = readstat_variable_get_index(variable);

    if (obs_index < 0 || obs_index >= chunk->count || col < 0 || col >= chunk->col_count)
        return READSTAT_HANDLER_OK;

    if (readstat_value_is_missing(value, variable))
        return READSTAT_HANDLER_OK;

    size_t cell_index = (size_t)obs_index * (size_t)chunk->col_count + (size_t)col;
    chunk->cells[cell_index] = data_format_value(value, variable);
    if (!chunk->cells[cell_index]) {
        fetch_ctx->error = DATA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    return READSTAT_HANDLER_OK;
}

static int data_fetch_variable_handler(int index, readstat_variable_t *variable, const char *val_labels, void *ctx) {
    (void)index;
    (void)variable;
    (void)val_labels;
    (void)ctx;
    return READSTAT_HANDLER_OK;
}

static void data_cache_entry_clear(DataCacheEntry *entry, int32_t col_count) {
    if (!entry)
        return;
    data_cells_free(entry->cells, entry->count, col_count);
    memset(entry, 0, sizeof(*entry));
}

static DataCacheEntry *data_cache_find(DataDoc *doc, int64_t chunk_offset) {
    for (int i = 0; i < DATA_CACHE_CAPACITY; i++) {
        DataCacheEntry *entry = &doc->cache[i];
        if (entry->in_use && entry->offset == chunk_offset) {
            entry->last_used = ++doc->cache_clock;
            doc->cache_hits++;
            return entry;
        }
    }
    doc->cache_misses++;
    return NULL;
}

static DataCacheEntry *data_cache_slot(DataDoc *doc) {
    DataCacheEntry *oldest = &doc->cache[0];
    for (int i = 0; i < DATA_CACHE_CAPACITY; i++) {
        DataCacheEntry *entry = &doc->cache[i];
        if (!entry->in_use)
            return entry;
        if (entry->last_used < oldest->last_used)
            oldest = entry;
    }
    data_cache_entry_clear(oldest, doc->meta.col_count);
    return oldest;
}

static DataCacheEntry *data_cache_store(DataDoc *doc, DataChunk *chunk) {
    DataCacheEntry *entry = data_cache_slot(doc);
    entry->in_use = 1;
    entry->offset = chunk->offset;
    entry->count = chunk->count;
    entry->cells = chunk->cells;
    entry->last_used = ++doc->cache_clock;
    chunk->cells = NULL;
    return entry;
}

static DataChunk *data_parse_memory_chunk(DataDoc *doc, int64_t chunk_offset, int32_t chunk_count) {
    DataChunk *chunk = data_chunk_alloc(chunk_offset, chunk_count, doc->meta.col_count);
    if (!chunk) {
        doc->last_error = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    for (int32_t row = 0; row < chunk_count; row++) {
        for (int32_t col = 0; col < doc->meta.col_count; col++) {
            size_t src = (size_t)(chunk_offset + row) * (size_t)doc->meta.col_count + (size_t)col;
            size_t dst = (size_t)row * (size_t)doc->meta.col_count + (size_t)col;
            if (doc->memory_cells[src]) {
                chunk->cells[dst] = data_strdup(doc->memory_cells[src]);
                if (!chunk->cells[dst]) {
                    data_chunk_free(chunk);
                    doc->last_error = DATA_CORE_ERROR_ALLOC;
                    return NULL;
                }
            }
        }
    }
    return chunk;
}

static DataChunk *data_parse_chunk(DataDoc *doc, int64_t chunk_offset, int32_t chunk_count) {
    if (doc->storage == DATA_STORAGE_MEMORY)
        return data_parse_memory_chunk(doc, chunk_offset, chunk_count);

    if (chunk_offset > LONG_MAX) {
        doc->last_error = DATA_CORE_ERROR_OVERFLOW;
        return NULL;
    }

    DataChunk *chunk = data_chunk_alloc(chunk_offset, chunk_count, doc->meta.col_count);
    if (!chunk) {
        doc->last_error = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    readstat_parser_t *parser = readstat_parser_init();
    if (!parser) {
        data_chunk_free(chunk);
        doc->last_error = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DataFetchCtx ctx = { .doc = doc, .chunk = chunk, .error = DATA_CORE_OK };
    readstat_set_variable_handler(parser, data_fetch_variable_handler);
    readstat_set_value_handler(parser, data_value_handler);
    readstat_set_row_offset(parser, (long)chunk_offset);
    readstat_set_row_limit(parser, (long)chunk_count);

    readstat_error_t err = readstat_parse_dta(parser, doc->path, &ctx);
    readstat_parser_free(parser);

    if (err != READSTAT_OK || ctx.error != DATA_CORE_OK) {
        data_chunk_free(chunk);
        doc->last_error = ctx.error != DATA_CORE_OK ? ctx.error : (int)err;
        return NULL;
    }

    return chunk;
}

static int data_copy_rows(DataChunk *out, int32_t out_row_start, const DataCacheEntry *entry,
        int32_t entry_row_start, int32_t row_count) {
    int32_t col_count = out->col_count;
    for (int32_t row = 0; row < row_count; row++) {
        for (int32_t col = 0; col < col_count; col++) {
            size_t src = (size_t)(entry_row_start + row) * (size_t)col_count + (size_t)col;
            size_t dst = (size_t)(out_row_start + row) * (size_t)col_count + (size_t)col;
            if (entry->cells[src]) {
                out->cells[dst] = data_strdup(entry->cells[src]);
                if (!out->cells[dst])
                    return 0;
            }
        }
    }
    return 1;
}

static DataDoc *data_open_stata(const char *path, int *out_err) {
    if (out_err)
        *out_err = DATA_CORE_OK;
    DataDoc *doc = data_doc_alloc(path, DATA_STORAGE_STATA, DATA_FILE_STATA, out_err);
    if (!doc)
        return NULL;

    readstat_parser_t *parser = readstat_parser_init();
    if (!parser) {
        data_close(doc);
        if (out_err)
            *out_err = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DataMetaParseCtx ctx = { .doc = doc, .error = DATA_CORE_OK };
    readstat_set_metadata_handler(parser, data_metadata_handler);
    readstat_set_variable_handler(parser, data_variable_handler);

    readstat_error_t err = readstat_parse_dta(parser, path, &ctx);
    readstat_parser_free(parser);

    if (err != READSTAT_OK || ctx.error != DATA_CORE_OK) {
        int code = ctx.error != DATA_CORE_OK ? ctx.error : (int)err;
        data_close(doc);
        if (out_err)
            *out_err = code;
        return NULL;
    }

    doc->last_error = DATA_CORE_OK;
    return doc;
}

DataDoc *data_open(const char *path, int *out_err) {
    if (out_err)
        *out_err = DATA_CORE_OK;
    if (!path || !path[0]) {
        if (out_err)
            *out_err = DATA_CORE_ERROR_BAD_ARGUMENT;
        return NULL;
    }

    if (data_extension_is(path, "dta"))
        return data_open_stata(path, out_err);
    if (data_extension_is(path, "rds"))
        return data_open_rds(path, out_err);
    if (data_extension_is(path, "mat"))
        return data_open_mat(path, out_err);

    if (out_err)
        *out_err = DATA_CORE_ERROR_UNSUPPORTED_FORMAT;
    return NULL;
}

const DataMeta *data_metadata(DataDoc *doc) {
    return doc ? &doc->meta : NULL;
}

DataChunk *data_fetch(DataDoc *doc, int64_t offset, int32_t count) {
    if (!doc || offset < 0 || count < 0) {
        if (doc)
            doc->last_error = DATA_CORE_ERROR_BAD_ARGUMENT;
        return NULL;
    }

    if (offset >= doc->meta.row_count)
        count = 0;
    else if ((int64_t)count > doc->meta.row_count - offset)
        count = (int32_t)(doc->meta.row_count - offset);

    DataChunk *out = data_chunk_alloc(offset, count, doc->meta.col_count);
    if (!out) {
        doc->last_error = DATA_CORE_ERROR_ALLOC;
        return NULL;
    }

    pthread_mutex_lock(&doc->lock);

    int32_t copied = 0;
    while (copied < count) {
        int64_t absolute_row = offset + copied;
        int64_t chunk_offset = (absolute_row / DATA_CHUNK_SIZE) * DATA_CHUNK_SIZE;
        int32_t chunk_count = DATA_CHUNK_SIZE;
        if (chunk_offset + chunk_count > doc->meta.row_count)
            chunk_count = (int32_t)(doc->meta.row_count - chunk_offset);

        DataCacheEntry *entry = data_cache_find(doc, chunk_offset);
        if (!entry) {
            DataChunk *parsed = data_parse_chunk(doc, chunk_offset, chunk_count);
            if (!parsed) {
                pthread_mutex_unlock(&doc->lock);
                data_chunk_free(out);
                return NULL;
            }
            entry = data_cache_store(doc, parsed);
            free(parsed);
        }

        int32_t entry_row = (int32_t)(absolute_row - entry->offset);
        int32_t available = entry->count - entry_row;
        int32_t needed = count - copied;
        int32_t rows = available < needed ? available : needed;
        if (rows <= 0) {
            doc->last_error = DATA_CORE_ERROR_BAD_ARGUMENT;
            pthread_mutex_unlock(&doc->lock);
            data_chunk_free(out);
            return NULL;
        }

        if (!data_copy_rows(out, copied, entry, entry_row, rows)) {
            doc->last_error = DATA_CORE_ERROR_ALLOC;
            pthread_mutex_unlock(&doc->lock);
            data_chunk_free(out);
            return NULL;
        }
        copied += rows;
    }

    doc->last_error = DATA_CORE_OK;
    pthread_mutex_unlock(&doc->lock);
    return out;
}

int data_last_error(DataDoc *doc) {
    return doc ? doc->last_error : DATA_CORE_ERROR_BAD_ARGUMENT;
}

DataCacheStats data_cache_stats(DataDoc *doc) {
    DataCacheStats stats = {0};
    if (!doc)
        return stats;

    pthread_mutex_lock(&doc->lock);
    stats.hits = doc->cache_hits;
    stats.misses = doc->cache_misses;
    stats.chunk_size = DATA_CHUNK_SIZE;
    for (int i = 0; i < DATA_CACHE_CAPACITY; i++) {
        if (doc->cache[i].in_use)
            stats.cached_chunks++;
    }
    pthread_mutex_unlock(&doc->lock);
    return stats;
}

const char *data_error_message(int code) {
    switch (code) {
        case DATA_CORE_OK:
            return "ok";
        case DATA_CORE_ERROR_ALLOC:
            return "memory allocation failed";
        case DATA_CORE_ERROR_BAD_ARGUMENT:
            return "bad argument";
        case DATA_CORE_ERROR_OVERFLOW:
            return "value outside supported range";
        case DATA_CORE_ERROR_UNSUPPORTED_FORMAT:
            return "unsupported file extension";
        case DATA_CORE_ERROR_UNSUPPORTED_DATA:
            return "file does not contain a supported tabular dataset";
        case DATA_CORE_ERROR_PARSE:
            return "failed to parse file";
        case DATA_CORE_ERROR_UNSUPPORTED_COMPRESSION:
            return "unsupported compressed RDS file";
        default:
            if (code > 0)
                return readstat_error_message((readstat_error_t)code);
            return "unknown data core error";
    }
}

void data_close(DataDoc *doc) {
    if (!doc)
        return;

    for (int i = 0; i < DATA_CACHE_CAPACITY; i++)
        data_cache_entry_clear(&doc->cache[i], doc->meta.col_count);
    data_memory_cells_free(doc->memory_cells, doc->meta.row_count, doc->meta.col_count);
    data_free_columns(&doc->meta);
    free(doc->path);
    pthread_mutex_destroy(&doc->lock);
    free(doc);
}
