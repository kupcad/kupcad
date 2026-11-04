/*
 * kupcad.h: libkupcad, the KupCAD core for a host in another language (src/capi.zig).
 *
 * It formats and lints a script, reads the parameters it declares, and builds its model in
 * any format the CLI exports. Every call returns a kupcad_result, never NULL, which the
 * caller frees with kupcad_result_free: its status, its bytes (the model, or the text or JSON
 * asked for), the message of what failed, and a build's report. Calls share nothing, so
 * threads may make them at once. The library writes nothing to the host's stdout or stderr
 * and logs nothing: all it has to say is in the result.
 *
 * A script reads only the files given with its call, and its exports go nowhere. It runs in
 * the calling process: a bug the core stops on stops the host too. Where that matters, run
 * the `kupcad` CLI as a process of its own. A process may fork between builds (a preforking
 * web server, multiprocessing): the last build to end ends the worker threads the builds
 * started, and each process starts its own again; but not while a build runs on another
 * thread.
 */
#ifndef KUPCAD_H
#define KUPCAD_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* The ABI this header declares, which kupcad_abi_version() returns. A host checks it before
 * any other call and refuses a library that returns another. */
#define KUPCAD_ABI_VERSION 1

typedef enum kupcad_status {
    KUPCAD_OK = 0,
    /* The script doesn't parse or compile, raises, or leaves no model to export. The message
     * says where and why: "2:5: Invalid expression ...", "RuntimeError: Plate too thin". */
    KUPCAD_SCRIPT_ERROR = 1,
    /* The call's own arguments: a format that isn't one, parameter values that aren't a JSON
     * object of names and values, files packed wrong. */
    KUPCAD_INVALID_ARGUMENT = 2,
    KUPCAD_OUT_OF_MEMORY = 3,
    /* A bug of the core's own (the formatter would change what the script does). */
    KUPCAD_INTERNAL_ERROR = 4
} kupcad_status;

/* What a call gives: read it with the kupcad_result_* functions, free it once. */
typedef struct kupcad_result kupcad_result;

/* KUPCAD_ABI_VERSION, as the library was built with it. */
uint32_t kupcad_abi_version(void);

/* What the library says of itself, as `kupcad version --json` does, in its data:
 * {"version": "0.1.9", "protocolVersion": 1, "os": "linux", "arch": "x86_64",
 *  "formats": ["stl", "glb", "gltf", "step", "3mf", "obj", "svg", "dxf"]}: the formats are
 * those kupcad_build takes. */
kupcad_result *kupcad_version(void);

/* `source` formatted, as `kupcad fmt` formats it, in the data. KUPCAD_SCRIPT_ERROR when it
 * doesn't parse, the message its first syntax error. `source` may be NULL when its length is 0,
 * as may every pointer given with a length below. */
kupcad_result *kupcad_format(const char *source, size_t source_len);

/* The findings of `source` as a JSON array in the data, each as `kupcad check --format json`
 * gives it, without its path: {"line", "column", "endLine", "endColumn", "offset", "length",
 * "severity", "rule", "code", "message", "fix"}. Syntax errors are findings, not failures. */
kupcad_result *kupcad_check(const char *source, size_t source_len);

/* The parameters `source` declares and its metadata, as JSON in the data: the schema
 * `kupcad doc` prints, {"meta": {...}, "parameters": [...]}. */
kupcad_result *kupcad_params(const char *source, size_t source_len);

/* Runs `source` and exports its model as `format` (one of kupcad_version's "formats": "stl",
 * "3mf", "glb"...; NULL, or another, is KUPCAD_INVALID_ARGUMENT), its bytes in the data, as
 * `kupcad build` writes them. Its report (below)
 * comes with it, whether the build succeeds or not.
 *
 * params_json: the parameter values, a JSON object of names and values as `kupcad build -P`
 *   reads them ({"width": 60, "label": "A"}); NULL for none.
 * files: the files the script imports, packed one after another, each as the length of its
 *   path, its path (UTF-8, from the script's folder: "lib/gears.kup"), the length of its
 *   content and its content, each length 4 bytes, little-endian; NULL for none.
 * memory_limit: the most memory, in bytes, the script may hold (`--memory-limit`): its values
 *   and its geometry graph, not the kernel's meshes; 0 for no limit. A script that needs more
 *   fails with "OutOfMemoryError: ...".
 * timeout_ms: the most time, in milliseconds, the build may take; 0 for no limit. A build that
 *   runs longer fails with "Time limit: ...": the time is checked every few thousand
 *   instructions, between geometry operations and after the export, so one long operation of
 *   the kernel's (a chain of booleans it computes as it meshes the model) finishes first.
 * draco: compress a GLB's or a glTF's meshes with Draco.
 */
kupcad_result *kupcad_build(const char *source, size_t source_len, const char *format,
                            const char *params_json, size_t params_json_len,
                            const uint8_t *files, size_t files_len,
                            uint64_t memory_limit, uint64_t timeout_ms, bool draco);

/* KUPCAD_OK, or what failed. */
kupcad_status kupcad_result_status(const kupcad_result *result);

/* The result's bytes, their length in `len` (which may be NULL): a model, or text or JSON in
 * UTF-8, not NUL-terminated. Empty (length 0) when the call failed. Valid until the result is
 * freed. */
const uint8_t *kupcad_result_data(const kupcad_result *result, size_t *len);

/* What failed, NUL-terminated UTF-8, its length in bytes in `len` (which may be NULL): a
 * message can hold a NUL of its own, quoting the script. NULL, and 0, when the call succeeded. */
const char *kupcad_result_message(const kupcad_result *result, size_t *len);

/* A build's report, NUL-terminated JSON: what the script printed (`puts`, `print`, `warn`) up
 * to 64 KB, and what it warned of, where:
 * {"output": "...", "outputCut": false,
 *  "warnings": [{"message": "...", "line": 3, "column": 1, "file": null}]}.
 * A warning's line and column are null where the script wasn't running (as the model was
 * meshed); its file is the imported file whose code warned, null for the script's own.
 * NULL for every other call, and for a build refused before it ran. */
const char *kupcad_result_report(const kupcad_result *result);

/* Frees the result and all it holds. NULL is ignored. */
void kupcad_result_free(kupcad_result *result);

#ifdef __cplusplus
}
#endif

#endif /* KUPCAD_H */
