#include "dta_core.h"

#include "../readstat/src/readstat.h"

#include <limits.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define DTA_CHUNK_SIZE 1000
#define DTA_CACHE_CAPACITY 12

typedef struct {
    int in_use;
    int64_t offset;
    int32_t count;
    char **cells;
    uint64_t last_used;
} DtaCacheEntry;

struct DtaDoc {
    char *path;
    DtaMeta meta;
    DtaCacheEntry cache[DTA_CACHE_CAPACITY];
    uint64_t cache_clock;
    int64_t cache_hits;
    int64_t cache_misses;
    int last_error;
    pthread_mutex_t lock;
};

typedef struct {
    DtaDoc *doc;
    int error;
} DtaMetaParseCtx;

typedef struct {
    DtaDoc *doc;
    DtaChunk *chunk;
    int error;
} DtaFetchCtx;

static char *dta_strdup(const char *s) {
    const char *value = s ? s : "";
    size_t len = strlen(value);
    char *copy = malloc(len + 1);
    if (!copy)
        return NULL;
    memcpy(copy, value, len + 1);
    return copy;
}

static void dta_free_columns(DtaMeta *meta) {
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

static int dta_cell_total_fits(int32_t count, int32_t col_count, size_t *out_total) {
    if (count < 0 || col_count < 0)
        return 0;
    if (col_count != 0 && (size_t)count > SIZE_MAX / (size_t)col_count)
        return 0;
    *out_total = (size_t)count * (size_t)col_count;
    return 1;
}

static DtaChunk *dta_chunk_alloc(int64_t offset, int32_t count, int32_t col_count) {
    size_t total = 0;
    if (!dta_cell_total_fits(count, col_count, &total))
        return NULL;

    DtaChunk *chunk = calloc(1, sizeof(*chunk));
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

static void dta_cells_free(char **cells, int32_t count, int32_t col_count) {
    size_t total = 0;
    if (!cells)
        return;
    if (dta_cell_total_fits(count, col_count, &total)) {
        for (size_t i = 0; i < total; i++)
            free(cells[i]);
    }
    free(cells);
}

void dta_chunk_free(DtaChunk *chunk) {
    if (!chunk)
        return;
    dta_cells_free(chunk->cells, chunk->count, chunk->col_count);
    free(chunk);
}

static int dta_format_decimals(const char *format) {
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

static int dta_format_uses_commas(const char *format) {
    return format && strchr(format, 'c') != NULL;
}

static double dta_numeric_as_double(readstat_value_t value) {
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

static char *dta_add_commas(const char *input) {
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
        return dta_strdup(input);

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

static char *dta_format_numeric(readstat_value_t value, readstat_variable_t *variable) {
    char buffer[96];
    const char *format = variable ? readstat_variable_get_format(variable) : NULL;
    int decimals = dta_format_decimals(format);

    if (decimals >= 0 && decimals < 20) {
        snprintf(buffer, sizeof(buffer), "%.*f", decimals, dta_numeric_as_double(value));
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

    if (dta_format_uses_commas(format))
        return dta_add_commas(buffer);
    return dta_strdup(buffer);
}

static char *dta_format_value(readstat_value_t value, readstat_variable_t *variable) {
    if (readstat_value_type_class(value) == READSTAT_TYPE_CLASS_STRING) {
        const char *s = readstat_string_value(value);
        return s ? dta_strdup(s) : NULL;
    }
    return dta_format_numeric(value, variable);
}

static int dta_metadata_handler(readstat_metadata_t *metadata, void *ctx) {
    DtaMetaParseCtx *parse_ctx = ctx;
    DtaDoc *doc = parse_ctx->doc;
    int64_t var_count = readstat_get_var_count(metadata);

    if (var_count < 0 || var_count > INT32_MAX) {
        parse_ctx->error = DTA_CORE_ERROR_OVERFLOW;
        return READSTAT_HANDLER_ABORT;
    }

    doc->meta.row_count = readstat_get_row_count(metadata);
    doc->meta.col_count = (int32_t)var_count;
    doc->meta.dataset_label = dta_strdup(readstat_get_file_label(metadata));
    if (!doc->meta.dataset_label) {
        parse_ctx->error = DTA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    if (doc->meta.col_count > 0) {
        doc->meta.columns = calloc((size_t)doc->meta.col_count, sizeof(DtaColumn));
        if (!doc->meta.columns) {
            parse_ctx->error = DTA_CORE_ERROR_ALLOC;
            return READSTAT_HANDLER_ABORT;
        }
    }
    return READSTAT_HANDLER_OK;
}

static int dta_variable_handler(int index, readstat_variable_t *variable, const char *val_labels, void *ctx) {
    (void)index;
    (void)val_labels;

    DtaMetaParseCtx *parse_ctx = ctx;
    DtaDoc *doc = parse_ctx->doc;
    int var_index = readstat_variable_get_index(variable);
    if (var_index < 0 || var_index >= doc->meta.col_count)
        return READSTAT_HANDLER_OK;

    DtaColumn *column = &doc->meta.columns[var_index];
    column->index = var_index;
    column->name = dta_strdup(readstat_variable_get_name(variable));
    column->label = dta_strdup(readstat_variable_get_label(variable));
    column->format = dta_strdup(readstat_variable_get_format(variable));
    column->type = readstat_variable_get_type_class(variable) == READSTAT_TYPE_CLASS_NUMERIC
        ? DTA_NUMERIC
        : DTA_STRING;

    if (!column->name || !column->label || !column->format) {
        parse_ctx->error = DTA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    return READSTAT_HANDLER_OK;
}

static int dta_value_handler(int obs_index, readstat_variable_t *variable, readstat_value_t value, void *ctx) {
    DtaFetchCtx *fetch_ctx = ctx;
    DtaChunk *chunk = fetch_ctx->chunk;
    int col = readstat_variable_get_index(variable);

    if (obs_index < 0 || obs_index >= chunk->count || col < 0 || col >= chunk->col_count)
        return READSTAT_HANDLER_OK;

    if (readstat_value_is_missing(value, variable))
        return READSTAT_HANDLER_OK;

    size_t cell_index = (size_t)obs_index * (size_t)chunk->col_count + (size_t)col;
    chunk->cells[cell_index] = dta_format_value(value, variable);
    if (!chunk->cells[cell_index]) {
        fetch_ctx->error = DTA_CORE_ERROR_ALLOC;
        return READSTAT_HANDLER_ABORT;
    }

    return READSTAT_HANDLER_OK;
}

static int dta_fetch_variable_handler(int index, readstat_variable_t *variable, const char *val_labels, void *ctx) {
    (void)index;
    (void)variable;
    (void)val_labels;
    (void)ctx;
    return READSTAT_HANDLER_OK;
}

static void dta_cache_entry_clear(DtaCacheEntry *entry, int32_t col_count) {
    if (!entry)
        return;
    dta_cells_free(entry->cells, entry->count, col_count);
    memset(entry, 0, sizeof(*entry));
}

static DtaCacheEntry *dta_cache_find(DtaDoc *doc, int64_t chunk_offset) {
    for (int i = 0; i < DTA_CACHE_CAPACITY; i++) {
        DtaCacheEntry *entry = &doc->cache[i];
        if (entry->in_use && entry->offset == chunk_offset) {
            entry->last_used = ++doc->cache_clock;
            doc->cache_hits++;
            return entry;
        }
    }
    doc->cache_misses++;
    return NULL;
}

static DtaCacheEntry *dta_cache_slot(DtaDoc *doc) {
    DtaCacheEntry *oldest = &doc->cache[0];
    for (int i = 0; i < DTA_CACHE_CAPACITY; i++) {
        DtaCacheEntry *entry = &doc->cache[i];
        if (!entry->in_use)
            return entry;
        if (entry->last_used < oldest->last_used)
            oldest = entry;
    }
    dta_cache_entry_clear(oldest, doc->meta.col_count);
    return oldest;
}

static DtaCacheEntry *dta_cache_store(DtaDoc *doc, DtaChunk *chunk) {
    DtaCacheEntry *entry = dta_cache_slot(doc);
    entry->in_use = 1;
    entry->offset = chunk->offset;
    entry->count = chunk->count;
    entry->cells = chunk->cells;
    entry->last_used = ++doc->cache_clock;
    chunk->cells = NULL;
    return entry;
}

static DtaChunk *dta_parse_chunk(DtaDoc *doc, int64_t chunk_offset, int32_t chunk_count) {
    if (chunk_offset > LONG_MAX) {
        doc->last_error = DTA_CORE_ERROR_OVERFLOW;
        return NULL;
    }

    DtaChunk *chunk = dta_chunk_alloc(chunk_offset, chunk_count, doc->meta.col_count);
    if (!chunk) {
        doc->last_error = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    readstat_parser_t *parser = readstat_parser_init();
    if (!parser) {
        dta_chunk_free(chunk);
        doc->last_error = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DtaFetchCtx ctx = { .doc = doc, .chunk = chunk, .error = DTA_CORE_OK };
    readstat_set_variable_handler(parser, dta_fetch_variable_handler);
    readstat_set_value_handler(parser, dta_value_handler);
    readstat_set_row_offset(parser, (long)chunk_offset);
    readstat_set_row_limit(parser, (long)chunk_count);

    readstat_error_t err = readstat_parse_dta(parser, doc->path, &ctx);
    readstat_parser_free(parser);

    if (err != READSTAT_OK || ctx.error != DTA_CORE_OK) {
        dta_chunk_free(chunk);
        doc->last_error = ctx.error != DTA_CORE_OK ? ctx.error : (int)err;
        return NULL;
    }

    return chunk;
}

static int dta_copy_rows(DtaChunk *out, int32_t out_row_start, const DtaCacheEntry *entry,
        int32_t entry_row_start, int32_t row_count) {
    int32_t col_count = out->col_count;
    for (int32_t row = 0; row < row_count; row++) {
        for (int32_t col = 0; col < col_count; col++) {
            size_t src = (size_t)(entry_row_start + row) * (size_t)col_count + (size_t)col;
            size_t dst = (size_t)(out_row_start + row) * (size_t)col_count + (size_t)col;
            if (entry->cells[src]) {
                out->cells[dst] = dta_strdup(entry->cells[src]);
                if (!out->cells[dst])
                    return 0;
            }
        }
    }
    return 1;
}

DtaDoc *dta_open(const char *path, int *out_err) {
    if (out_err)
        *out_err = DTA_CORE_OK;
    if (!path || !path[0]) {
        if (out_err)
            *out_err = DTA_CORE_ERROR_BAD_ARGUMENT;
        return NULL;
    }

    DtaDoc *doc = calloc(1, sizeof(*doc));
    if (!doc) {
        if (out_err)
            *out_err = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    doc->path = dta_strdup(path);
    if (!doc->path) {
        free(doc);
        if (out_err)
            *out_err = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    pthread_mutex_init(&doc->lock, NULL);

    readstat_parser_t *parser = readstat_parser_init();
    if (!parser) {
        dta_close(doc);
        if (out_err)
            *out_err = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    DtaMetaParseCtx ctx = { .doc = doc, .error = DTA_CORE_OK };
    readstat_set_metadata_handler(parser, dta_metadata_handler);
    readstat_set_variable_handler(parser, dta_variable_handler);

    readstat_error_t err = readstat_parse_dta(parser, path, &ctx);
    readstat_parser_free(parser);

    if (err != READSTAT_OK || ctx.error != DTA_CORE_OK) {
        int code = ctx.error != DTA_CORE_OK ? ctx.error : (int)err;
        dta_close(doc);
        if (out_err)
            *out_err = code;
        return NULL;
    }

    doc->last_error = DTA_CORE_OK;
    return doc;
}

const DtaMeta *dta_metadata(DtaDoc *doc) {
    return doc ? &doc->meta : NULL;
}

DtaChunk *dta_fetch(DtaDoc *doc, int64_t offset, int32_t count) {
    if (!doc || offset < 0 || count < 0) {
        if (doc)
            doc->last_error = DTA_CORE_ERROR_BAD_ARGUMENT;
        return NULL;
    }

    if (offset >= doc->meta.row_count)
        count = 0;
    else if ((int64_t)count > doc->meta.row_count - offset)
        count = (int32_t)(doc->meta.row_count - offset);

    DtaChunk *out = dta_chunk_alloc(offset, count, doc->meta.col_count);
    if (!out) {
        doc->last_error = DTA_CORE_ERROR_ALLOC;
        return NULL;
    }

    pthread_mutex_lock(&doc->lock);

    int32_t copied = 0;
    while (copied < count) {
        int64_t absolute_row = offset + copied;
        int64_t chunk_offset = (absolute_row / DTA_CHUNK_SIZE) * DTA_CHUNK_SIZE;
        int32_t chunk_count = DTA_CHUNK_SIZE;
        if (chunk_offset + chunk_count > doc->meta.row_count)
            chunk_count = (int32_t)(doc->meta.row_count - chunk_offset);

        DtaCacheEntry *entry = dta_cache_find(doc, chunk_offset);
        if (!entry) {
            DtaChunk *parsed = dta_parse_chunk(doc, chunk_offset, chunk_count);
            if (!parsed) {
                pthread_mutex_unlock(&doc->lock);
                dta_chunk_free(out);
                return NULL;
            }
            entry = dta_cache_store(doc, parsed);
            free(parsed);
        }

        int32_t entry_row = (int32_t)(absolute_row - entry->offset);
        int32_t available = entry->count - entry_row;
        int32_t needed = count - copied;
        int32_t rows = available < needed ? available : needed;
        if (rows <= 0) {
            doc->last_error = DTA_CORE_ERROR_BAD_ARGUMENT;
            pthread_mutex_unlock(&doc->lock);
            dta_chunk_free(out);
            return NULL;
        }

        if (!dta_copy_rows(out, copied, entry, entry_row, rows)) {
            doc->last_error = DTA_CORE_ERROR_ALLOC;
            pthread_mutex_unlock(&doc->lock);
            dta_chunk_free(out);
            return NULL;
        }
        copied += rows;
    }

    doc->last_error = DTA_CORE_OK;
    pthread_mutex_unlock(&doc->lock);
    return out;
}

int dta_last_error(DtaDoc *doc) {
    return doc ? doc->last_error : DTA_CORE_ERROR_BAD_ARGUMENT;
}

DtaCacheStats dta_cache_stats(DtaDoc *doc) {
    DtaCacheStats stats = {0};
    if (!doc)
        return stats;

    pthread_mutex_lock(&doc->lock);
    stats.hits = doc->cache_hits;
    stats.misses = doc->cache_misses;
    stats.chunk_size = DTA_CHUNK_SIZE;
    for (int i = 0; i < DTA_CACHE_CAPACITY; i++) {
        if (doc->cache[i].in_use)
            stats.cached_chunks++;
    }
    pthread_mutex_unlock(&doc->lock);
    return stats;
}

const char *dta_error_message(int code) {
    switch (code) {
        case DTA_CORE_OK:
            return "ok";
        case DTA_CORE_ERROR_ALLOC:
            return "memory allocation failed";
        case DTA_CORE_ERROR_BAD_ARGUMENT:
            return "bad argument";
        case DTA_CORE_ERROR_OVERFLOW:
            return "value outside supported range";
        default:
            if (code > 0)
                return readstat_error_message((readstat_error_t)code);
            return "unknown DTA core error";
    }
}

void dta_close(DtaDoc *doc) {
    if (!doc)
        return;

    for (int i = 0; i < DTA_CACHE_CAPACITY; i++)
        dta_cache_entry_clear(&doc->cache[i], doc->meta.col_count);
    dta_free_columns(&doc->meta);
    free(doc->path);
    pthread_mutex_destroy(&doc->lock);
    free(doc);
}
