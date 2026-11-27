EXTENSION = pg_index_steward
MODULE_big = pg_index_steward
OBJS = src/steward.o vendor/hypopg/hypopg.o vendor/hypopg/hypopg_index.o \
       vendor/hypopg/import/hypopg_import.o vendor/hypopg/import/hypopg_import_index.o
PG_CPPFLAGS += -I$(srcdir)/vendor/hypopg
SHLIB_LINK += -Wl,--version-script=$(srcdir)/src/exports.map
DATA = $(wildcard sql/pg_index_steward--*.sql)
PGFILEDESC = "PG Index Steward - workload-aware index management"
PG_CONFIG ?= pg_config
override enable_rpath = no
PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
