EXTENSION = merge_ips
DATA = merge_ips--1.0.sql
EXTRA_CLEAN = *~

PGXS := $(shell $(PG_CONFIG) --pgxs)
include $(PGXS)
