#!/usr/bin/tclsh
#
# To build a single huge source file holding all of SQLite (or at
# least the core components - the test harness, shell, and TCL 
# interface are omitted.) first do
#
#      make target_source
#
# The make target above moves all of the source code files into
# a subdirectory named "tsrc".  (This script expects to find the files
# there and will not work if they are not found.)  There are a few
# generated C code files that are also added to the tsrc directory.
# For example, the "parse.c" and "parse.h" files to implement the
# the parser are derived from "parse.y" using lemon.  And the 
# "keywordhash.h" files is generated by a program named "mkkeywordhash".
#
# After the "tsrc" directory has been created and populated, run
# this script:
#
#      tclsh mksqlite3c.tcl
#
# The amalgamated SQLite code will be written into sqlite3.c
#

# Begin by reading the "sqlite3.h" header file.  Extract the version number
# from in this file.  The version number is needed to generate the header
# comment of the amalgamation.
#
if {[lsearch $argv --nostatic]>=0} {
  set addstatic 0
} else {
  set addstatic 1
}
if {[lsearch $argv --linemacros]>=0} {
  set linemacros 1
} else {
  set linemacros 0
}
set in [open tsrc/sqlite3.h]
set cnt 0
set VERSION ?????
while {![eof $in]} {
  set line [gets $in]
  if {$line=="" && [eof $in]} break
  incr cnt
  regexp {#define\s+SQLITE_VERSION\s+"(.*)"} $line all VERSION
}
close $in

# Open the output file and write a header comment at the beginning
# of the file.
#
set out [open sqlite3.c w]
# Force the output to use unix line endings, even on Windows.
fconfigure $out -translation lf
set today [clock format [clock seconds] -format "%Y-%m-%d %H:%M:%S UTC" -gmt 1]
puts $out [subst \
{/******************************************************************************
** This file is an amalgamation of many separate C source files from SQLite
** version $VERSION.  By combining all the individual C code files into this 
** single large file, the entire code can be compiled as a single translation
** unit.  This allows many compilers to do optimizations that would not be
** possible if the files were compiled separately.  Performance improvements
** of 5% or more are commonly seen when SQLite is compiled as a single
** translation unit.
**
** This file is all you need to compile SQLite.  To use SQLite in other
** programs, you need this file and the "sqlite3.h" header file that defines
** the programming interface to the SQLite library.  (If you do not have 
** the "sqlite3.h" header file at hand, you will find a copy embedded within
** the text of this file.  Search for "Begin file sqlite3.h" to find the start
** of the embedded sqlite3.h header file.) Additional code files may be needed
** if you want a wrapper to interface SQLite with your choice of programming
** language. The code for the "sqlite3" command-line shell is also in a
** separate file. This file contains only code for the core SQLite library.
*/
#define SQLITE_CORE 1
#define SQLITE_AMALGAMATION 1}]
if {$addstatic} {
  puts $out \
{#ifndef SQLITE_PRIVATE
# define SQLITE_PRIVATE static
#endif
#ifndef SQLITE_API
# define SQLITE_API
#endif}
}

# These are the header files used by SQLite.  The first time any of these 
# files are seen in a #include statement in the C code, include the complete
# text of the file in-line.  The file only needs to be included once.
#
foreach hdr {
   btree.h
   btreeInt.h
   fts3.h
   fts3Int.h
   fts3_hash.h
   fts3_tokenizer.h
   hash.h
   hwtime.h
   keywordhash.h
   mutex.h
   opcodes.h
   os_common.h
   os.h
   pager.h
   parse.h
   pcache.h
   rtree.h
   sqlite3ext.h
   sqlite3.h
   sqliteicu.h
   sqliteInt.h
   sqliteLimit.h
   vdbe.h
   vdbeInt.h
   wal.h
} {
  set available_hdr($hdr) 1
}
set available_hdr(sqliteInt.h) 0

# 78 stars used for comment formatting.
set s78 \
{*****************************************************************************}

# Insert a comment into the code
#
proc section_comment {text} {
  global out s78
  set n [string length $text]
  set nstar [expr {60 - $n}]
  set stars [string range $s78 0 $nstar]
  puts $out "/************** $text $stars/"
}

# Read the source file named $filename and write it into the
# sqlite3.c output file.  If any #include statements are seen,
# process them approprately.
#
proc copy_file {filename} {
  global seen_hdr available_hdr out addstatic linemacros
  set ln 0
  set tail [file tail $filename]
  section_comment "Begin file $tail"
  if {$linemacros} {puts $out "#line 1 \"$filename\""}
  set in [open $filename r]
  set varpattern {^[a-zA-Z][a-zA-Z_0-9 *]+(sqlite3[_a-zA-Z0-9]+)(\[|;| =)}
  set declpattern {[a-zA-Z][a-zA-Z_0-9 ]+ \**(sqlite3[_a-zA-Z0-9]+)\(}
  if {[file extension $filename]==".h"} {
    set declpattern " *$declpattern"
  }
  set declpattern ^$declpattern
  while {![eof $in]} {
    set line [gets $in]
    incr ln
    if {[regexp {^\s*#\s*include\s+["<]([^">]+)[">]} $line all hdr]} {
      if {[info exists available_hdr($hdr)]} {
        if {$available_hdr($hdr)} {
          if {$hdr!="os_common.h" && $hdr!="hwtime.h"} {
            set available_hdr($hdr) 0
          }
          section_comment "Include $hdr in the middle of $tail"
          copy_file tsrc/$hdr
          section_comment "Continuing where we left off in $tail"
          if {$linemacros} {puts $out "#line [expr {$ln+1}] \"$filename\""}
        }
      } elseif {![info exists seen_hdr($hdr)]} {
        set seen_hdr($hdr) 1
        puts $out $line
      } else {
        puts $out "/* $line */"
      }
    } elseif {[regexp {^#ifdef __cplusplus} $line]} {
      puts $out "#if 0"
    } elseif {!$linemacros && [regexp {^#line} $line]} {
      # Skip #line directives.
    } elseif {$addstatic && ![regexp {^(static|typedef)} $line]} {
      regsub {^SQLITE_API } $line {} line
      if {[regexp $declpattern $line all funcname]} {
        # Add the SQLITE_PRIVATE or SQLITE_API keyword before functions.
        # so that linkage can be modified at compile-time.
        if {[regexp {^sqlite3_} $funcname]} {
          puts $out "SQLITE_API $line"
        } else {
          puts $out "SQLITE_PRIVATE $line"
        }
      } elseif {[regexp $varpattern $line all varname]} {
        # Add the SQLITE_PRIVATE before variable declarations or
        # definitions for internal use
        if {![regexp {^sqlite3_} $varname]} {
          regsub {^extern } $line {} line
          puts $out "SQLITE_PRIVATE $line"
        } else {
          if {[regexp {const char sqlite3_version\[\];} $line]} {
            set line {const char sqlite3_version[] = SQLITE_VERSION;}
          }
          regsub {^SQLITE_EXTERN } $line {} line
          puts $out "SQLITE_API $line"
        }
      } elseif {[regexp {^(SQLITE_EXTERN )?void \(\*sqlite3IoTrace\)} $line]} {
        regsub {^SQLITE_EXTERN } $line {} line
        puts $out "SQLITE_PRIVATE $line"
      } elseif {[regexp {^void \(\*sqlite3Os} $line]} {
        puts $out "SQLITE_PRIVATE $line"
      } else {
        puts $out $line
      }
    } else {
      puts $out $line
    }
  }
  close $in
  section_comment "End of $tail"
}


# Process the source files.  Process files containing commonly
# used subroutines first in order to help the compiler find
# inlining opportunities.
#
foreach file {
   sqliteInt.h

   global.c
   ctime.c
   status.c
   date.c
   os.c

   fault.c
   mem0.c
   mem1.c
   mem2.c
   mem3.c
   mem5.c
   mutex.c
   mutex_noop.c
   mutex_unix.c
   mutex_w32.c
   malloc.c
   printf.c
   random.c
   utf.c
   util.c
   hash.c
   opcodes.c

   os_unix.c
   os_win.c

   bitvec.c
   pcache.c
   pcache1.c
   rowset.c
   pager.c
   wal.c

   btmutex.c
   btree.c
   backup.c

   vdbemem.c
   vdbeaux.c
   vdbeapi.c
   vdbetrace.c
   vdbe.c
   vdbeblob.c
   vdbesort.c
   journal.c
   memjournal.c

   walker.c
   resolve.c
   expr.c
   alter.c
   analyze.c
   attach.c
   auth.c
   build.c
   callback.c
   delete.c
   func.c
   fkey.c
   insert.c
   legacy.c
   loadext.c
   pragma.c
   prepare.c
   select.c
   table.c
   trigger.c
   update.c
   vacuum.c
   vtab.c
   where.c

   parse.c

   tokenize.c
   complete.c

   main.c
   notify.c

   fts3.c
   fts3_aux.c
   fts3_expr.c
   fts3_hash.c
   fts3_porter.c
   fts3_tokenizer.c
   fts3_tokenizer1.c
   fts3_tokenize_vtab.c
   fts3_write.c
   fts3_snippet.c
   fts3_unicode.c
   fts3_unicode2.c

   rtree.c
   icu.c
   fts3_icu.c
} {
  copy_file tsrc/$file
}

close $out
