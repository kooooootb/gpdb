override CPPFLAGS := -I$(top_builddir)/src/backend/gporca/libgpos/include $(CPPFLAGS)
override CPPFLAGS := -I$(top_builddir)/src/backend/gporca/libgpopt/include $(CPPFLAGS)
override CPPFLAGS := -I$(top_builddir)/src/backend/gporca/libnaucrates/include $(CPPFLAGS)
override CPPFLAGS := -I$(top_builddir)/src/backend/gporca/libgpdbcost/include $(CPPFLAGS)
# Do not omit frame pointer. Even with RELEASE builds, it is used for
# backtracing.
override CPPFLAGS := -Wextra -Wpedantic -Wno-variadic-macros -Wunused-but-set-variable -fno-omit-frame-pointer $(CPPFLAGS)
override CPPFLAGS := -std=c++11 $(CPPFLAGS)
