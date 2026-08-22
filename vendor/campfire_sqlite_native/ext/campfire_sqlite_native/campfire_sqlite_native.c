#include <ruby.h>
#include <sqlite3ext.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#if !defined(_WIN32)
#include <sys/stat.h>
#include <unistd.h>
#endif

typedef struct campfire_sqlite_registration {
    uint64_t id;
    sqlite3 *database;
    const sqlite3_api_routines *api;
    struct campfire_sqlite_registration *next;
} campfire_sqlite_registration;

static campfire_sqlite_registration *campfire_sqlite_registrations;
static campfire_sqlite_registration *campfire_sqlite_pending_registration;
static uint64_t campfire_sqlite_next_registration_id = 1;

/* Unix VFS file prefix used to reach h. Validate its public anchors before use. */
typedef struct campfire_sqlite_unix_file {
    const sqlite3_io_methods *methods;
    sqlite3_vfs *vfs;
    void *inode;
    int descriptor;
} campfire_sqlite_unix_file;

#if defined(_WIN32)
#define CAMPFIRE_SQLITE_EXPORT __declspec(dllexport)
#else
#define CAMPFIRE_SQLITE_EXPORT __attribute__((visibility("default")))
#endif

static void
campfire_sqlite_registration_anchor(sqlite3_context *context, int argc, sqlite3_value **argv)
{
    (void)context;
    (void)argc;
    (void)argv;
}

static void
campfire_sqlite_registration_destroy(void *data)
{
    campfire_sqlite_registration *registration = data;
    campfire_sqlite_registration **cursor = &campfire_sqlite_registrations;

    if (campfire_sqlite_pending_registration == registration) {
        campfire_sqlite_pending_registration = NULL;
    }
    while (*cursor != NULL && *cursor != registration) {
        cursor = &(*cursor)->next;
    }
    if (*cursor == registration) {
        *cursor = registration->next;
    }

    free(registration);
}

static VALUE
campfire_sqlite_take_registration(VALUE self)
{
    campfire_sqlite_registration *registration = campfire_sqlite_pending_registration;

    (void)self;
    if (registration == NULL) {
        rb_raise(rb_eRuntimeError, "Campfire SQLite registration is unavailable");
    }

    campfire_sqlite_pending_registration = NULL;
    return ULL2NUM(registration->id);
}

static campfire_sqlite_registration *
campfire_sqlite_registration_for_id(VALUE registration_id)
{
    uint64_t id = NUM2ULL(registration_id);
    campfire_sqlite_registration *registration = campfire_sqlite_registrations;

    while (registration != NULL && registration->id != id) {
        registration = registration->next;
    }
    if (registration == NULL) {
        rb_raise(rb_eRuntimeError, "Campfire SQLite registration is closed");
    }

    return registration;
}

static VALUE
campfire_sqlite_main_database_moved(VALUE self, VALUE registration_id)
{
    campfire_sqlite_registration *registration = campfire_sqlite_registration_for_id(registration_id);
    int moved = 0;
    int status;

    (void)self;

    status = registration->api->file_control(
        registration->database,
        "main",
        SQLITE_FCNTL_HAS_MOVED,
        &moved
    );
    if (status != SQLITE_OK) {
        rb_raise(
            rb_eRuntimeError,
            "Campfire SQLite main-file identity cannot be verified (status %d)",
            status
        );
    }

    return moved ? Qtrue : Qfalse;
}

static VALUE
campfire_sqlite_main_database_descriptor(VALUE self, VALUE registration_id)
{
#if defined(_WIN32)
    (void)self;
    (void)registration_id;
    rb_raise(rb_eRuntimeError, "Campfire SQLite main descriptor requires a Unix VFS");
#else
    campfire_sqlite_registration *registration = campfire_sqlite_registration_for_id(registration_id);
    sqlite3_file *file = NULL;
    sqlite3_vfs *vfs = NULL;
    campfire_sqlite_unix_file *unix_file;
    struct stat metadata;
    int status;

    (void)self;
    status = registration->api->file_control(
        registration->database,
        "main",
        SQLITE_FCNTL_FILE_POINTER,
        &file
    );
    if (status != SQLITE_OK || file == NULL || file->pMethods == NULL) {
        rb_raise(
            rb_eRuntimeError,
            "Campfire SQLite main file object is unavailable (status %d)",
            status
        );
    }

    status = registration->api->file_control(
        registration->database,
        "main",
        SQLITE_FCNTL_VFS_POINTER,
        &vfs
    );
    if (status != SQLITE_OK || vfs == NULL || vfs->zName == NULL ||
        strncmp(vfs->zName, "unix", 4) != 0 ||
        vfs->szOsFile < (int)(offsetof(campfire_sqlite_unix_file, descriptor) + sizeof(int))) {
        rb_raise(
            rb_eRuntimeError,
            "Campfire SQLite main descriptor requires a compatible Unix VFS (status %d)",
            status
        );
    }

    unix_file = (campfire_sqlite_unix_file *)file;
    if (unix_file->methods != file->pMethods || unix_file->vfs != vfs ||
        unix_file->descriptor < 0 || fstat(unix_file->descriptor, &metadata) != 0 ||
        !S_ISREG(metadata.st_mode)) {
        rb_raise(rb_eRuntimeError, "Campfire SQLite main descriptor cannot be verified");
    }

    return INT2NUM(unix_file->descriptor);
#endif
}

CAMPFIRE_SQLITE_EXPORT int
sqlite3_campfiresqlitenative_init(
    sqlite3 *database,
    char **error_message,
    const sqlite3_api_routines *api
)
{
    campfire_sqlite_registration *registration;
    int status;

    (void)error_message;
    registration = malloc(sizeof(*registration));
    if (registration == NULL) {
        return SQLITE_NOMEM;
    }
    if (campfire_sqlite_next_registration_id == 0) {
        free(registration);
        return SQLITE_TOOBIG;
    }

    registration->id = campfire_sqlite_next_registration_id++;
    registration->database = database;
    registration->api = api;
    registration->next = NULL;
    /* SQLite's function destructor owns the registration for the connection lifetime. */
    status = api->create_function_v2(
        database,
        "campfire_sqlite_native_registration",
        0,
        SQLITE_UTF8 | SQLITE_DIRECTONLY,
        registration,
        campfire_sqlite_registration_anchor,
        NULL,
        NULL,
        campfire_sqlite_registration_destroy
    );
    if (status != SQLITE_OK) {
        return status;
    }

    registration->next = campfire_sqlite_registrations;
    campfire_sqlite_registrations = registration;
    campfire_sqlite_pending_registration = registration;
    return SQLITE_OK;
}

RUBY_FUNC_EXPORTED void
Init_campfire_sqlite_native(void)
{
    VALUE module = rb_define_module("CampfireSQLiteNative");

    rb_define_singleton_method(module, "take_registration", campfire_sqlite_take_registration, 0);
    rb_define_singleton_method(
        module,
        "native_main_database_moved?",
        campfire_sqlite_main_database_moved,
        1
    );
    rb_define_singleton_method(
        module,
        "native_main_database_descriptor",
        campfire_sqlite_main_database_descriptor,
        1
    );
}
