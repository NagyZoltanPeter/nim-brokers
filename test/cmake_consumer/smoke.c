/*
 * Pure-C smoke test for the generated mylib CMake package.
 * Confirms the IMPORTED target links and the runtime loads: create a
 * context, immediately shut it down, exit 0.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mylib.h"

#define EXPECTED_VERSION "1.0.0"

int main(void) {
    const char* v = mylib_version();
    if (v == NULL || strcmp(v, EXPECTED_VERSION) != 0) {
        fprintf(stderr,
                "mylib_version mismatch: got '%s', expected '" EXPECTED_VERSION "'\n",
                v ? v : "(null)");
        return 10;
    }

    mylibCreateContextResult res = mylib_createContext();
    if (res.error_message != NULL) {
        fprintf(stderr, "mylib_createContext failed: %s\n", res.error_message);
        free_mylib_create_context_result(&res);
        return 1;
    }
    uint32_t ctx = res.ctx;
    free_mylib_create_context_result(&res);

    if (ctx == 0) {
        fprintf(stderr, "mylib_createContext returned ctx=0\n");
        return 2;
    }

    mylib_shutdown(ctx);
    printf("smoke_c: OK (ctx=%u)\n", ctx);
    return 0;
}
