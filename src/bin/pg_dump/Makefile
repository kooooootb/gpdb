#-------------------------------------------------------------------------
#
# Makefile for src/bin/pg_dump
#
# Portions Copyright (c) 1996-2014, PostgreSQL Global Development Group
# Portions Copyright (c) 1994, Regents of the University of California
#
# src/bin/pg_dump/Makefile
#
#-------------------------------------------------------------------------

PGFILEDESC = "pg_dump/pg_restore/pg_dumpall - backup and restore PostgreSQL databases"
PGAPPICON=win32

subdir = src/bin/pg_dump
top_builddir = ../../..
include $(top_builddir)/src/Makefile.global

# The frontend doesn't need everything that's in LIBS, some are backend only
LIBS := $(filter-out -lresolv, $(LIBS))
# This program isn't interactive, so doesn't need these
LIBS := $(filter-out -lreadline -ledit -ltermcap -lncurses -lcurses -lcurl , $(LIBS))


# the use of tempnam in pg_backup_tar.c causes a warning when using newer versions of GCC
override CPPFLAGS := -Wno-deprecated-declarations -I$(libpq_srcdir) $(CPPFLAGS)

ifeq ($(PORTNAME),openbsd)
override CFLAGS += -pthread
endif

OBJS=	pg_backup_archiver.o pg_backup_db.o pg_backup_custom.o \
	pg_backup_null.o pg_backup_tar.o pg_backup_directory.o \
	pg_backup_utils.o parallel.o compress_io.o dumputils.o hashfn.o $(WIN32RES)

KEYWRDOBJS = keywords.o kwlookup.o

kwlookup.c: % : $(top_srcdir)/src/backend/parser/%
	rm -f $@ && $(LN_S) $< .

all: pg_dump pg_restore pg_dumpall

pg_dump: pg_dump.o pg_dump_segment_helper.o common.o pg_dump_sort.o $(OBJS) $(KEYWRDOBJS) | submake-libpq submake-libpgport
	$(CC) $(CFLAGS) pg_dump.o pg_dump_segment_helper.o common.o pg_dump_sort.o $(KEYWRDOBJS) $(OBJS) $(libpq_pgport) $(LDFLAGS) $(LDFLAGS_EX) $(LIBS) -o $@$(X)

pg_restore: pg_restore.o $(OBJS) $(KEYWRDOBJS) | submake-libpq submake-libpgport
	$(CC) $(CFLAGS) pg_restore.o $(KEYWRDOBJS) $(OBJS) $(libpq_pgport) $(LDFLAGS) $(LDFLAGS_EX) $(LIBS) -o $@$(X)

pg_dumpall: pg_dumpall.o dumputils.o $(KEYWRDOBJS) | submake-libpq submake-libpgport
	$(CC) $(CFLAGS) pg_dumpall.o dumputils.o $(KEYWRDOBJS) $(WIN32RES) $(libpq_pgport) $(LDFLAGS) $(LDFLAGS_EX) $(LIBS) -o $@$(X)

install: all installdirs
	$(INSTALL_PROGRAM) pg_dump$(X) '$(DESTDIR)$(bindir)'/pg_dump$(X)
	$(INSTALL_PROGRAM) pg_restore$(X) '$(DESTDIR)$(bindir)'/pg_restore$(X)
	$(INSTALL_PROGRAM) pg_dumpall$(X) '$(DESTDIR)$(bindir)'/pg_dumpall$(X)

installdirs:
	$(MKDIR_P) '$(DESTDIR)$(bindir)'

uninstall:
	rm -f $(addprefix '$(DESTDIR)$(bindir)'/, pg_dump$(X) pg_restore$(X) pg_dumpall$(X))

clean distclean maintainer-clean:
	$(MAKE) -C test clean
	rm -f pg_dump$(X) pg_restore$(X) pg_dumpall$(X) $(OBJS) pg_dump.o common.o pg_dump_sort.o pg_restore.o pg_dumpall.o pg_dump_segment_helper.o kwlookup.c $(KEYWRDOBJS)
