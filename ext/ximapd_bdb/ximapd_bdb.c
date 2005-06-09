/*
 * $Id$
 * Copyright (C) 2005  Shugo Maeda <shugo@ruby-lang.org>
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE REGENTS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE REGENTS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#include <ruby.h>
#include <db.h>

static VALUE eBDBError;

static void
check_bdb_error(int dberr)
{
    if (dberr)
	rb_raise(eBDBError, "%s", db_strerror(dberr));
}

static void
bdb_free(DB *db)
{
    if (db) {
	db->close(db, 0);
    }
}

static VALUE
bdb_alloc(VALUE klass)
{
    return Data_Wrap_Struct(klass, NULL, bdb_free, NULL);
}

static DB *
get_db(VALUE obj)
{
    if (DATA_PTR(obj) == NULL) {
	rb_raise(eBDBError, "db is already closed");
    }
    return (DB *) DATA_PTR(obj);
}

static VALUE
bdb_close(VALUE self)
{
    DB *db = get_db(self);

    db->close(db, 0);
    DATA_PTR(self) = NULL;
    return Qnil;
}

static VALUE
bdb_s_open(int argc, VALUE *argv, VALUE klass)
{
    VALUE db = rb_class_new_instance(argc, argv, klass);
    if (rb_block_given_p()) {
	return rb_ensure(rb_yield, db, bdb_close, db);
    }
    else {
	return db;
    }
}

static VALUE
bdb_initialize(int argc, VALUE *argv, VALUE self)
{
    rb_raise(eBDBError, "BDB::DB is an abstract class");
    return Qnil;
}

static VALUE
bdb_aref(VALUE self, VALUE key)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;
    VALUE result;

    SafeStringValue(key);
    db_key.data = RSTRING(key)->ptr;
    db_key.size = RSTRING(key)->len;
    db_value.flags = DB_DBT_MALLOC;
    db = get_db(self);
    dberr = db->get(db, NULL, &db_key, &db_value, 0);
    if (dberr == DB_NOTFOUND)
	return Qnil;
    check_bdb_error(dberr);
    result = rb_tainted_str_new(db_value.data, db_value.size);
    free(db_value.data);
    return result;
}

static VALUE
bdb_aset(VALUE self, VALUE key, VALUE value)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;

    SafeStringValue(key);
    SafeStringValue(value);
    db_key.data = RSTRING(key)->ptr;
    db_key.size = RSTRING(key)->len;
    db_value.data = RSTRING(value)->ptr;
    db_value.size = RSTRING(value)->len;
    db = get_db(self);
    dberr = db->put(db, NULL, &db_key, &db_value, 0);
    check_bdb_error(dberr);
    return value;
}

static VALUE
bdb_has_key(VALUE self, VALUE key)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;

    SafeStringValue(key);
    db_key.data = RSTRING(key)->ptr;
    db_key.size = RSTRING(key)->len;
    db_value.flags = DB_DBT_MALLOC;
    db = get_db(self);
    dberr = db->get(db, NULL, &db_key, &db_value, 0);
    if (dberr == DB_NOTFOUND)
	return Qfalse;
    check_bdb_error(dberr);
    free(db_value.data);
    return Qtrue;
}

static VALUE
bdb_sync(VALUE self)
{
    DB *db = get_db(self);

    db->sync(db, 0);
    return Qnil;
}

static void
specific_bdb_initialize(DBTYPE type, int argc, VALUE *argv, VALUE self)
{
    VALUE vfilename, venv, vflags, vmode;
    char *filename;
    int dberr, flags = 0, mode = 0777;
    DB *db;

    rb_scan_args(argc, argv, "13", &vfilename, &venv, &vflags, &vmode);
    SafeStringValue(vfilename);
    filename = RSTRING(vfilename)->ptr;
    if (!NIL_P(vflags))
	flags = NUM2INT(vflags);
    if (!NIL_P(vmode))
	mode = NUM2INT(vmode);
    if ((dberr = db_create(&db, NULL, 0)) == 0) {
	if ((dberr = db->open(db, NULL, filename, NULL,
			      type, flags, mode)) != 0) {
	    db->close(db, 0);
	}
    }
    check_bdb_error(dberr);
    DATA_PTR(self) = db;
}

static VALUE
btree_initialize(int argc, VALUE *argv, VALUE self)
{
    specific_bdb_initialize(DB_BTREE, argc, argv, self);
    return Qnil;
}

static VALUE
hash_initialize(int argc, VALUE *argv, VALUE self)
{
    specific_bdb_initialize(DB_HASH, argc, argv, self);
    return Qnil;
}

static VALUE
recno_initialize(int argc, VALUE *argv, VALUE self)
{
    specific_bdb_initialize(DB_RECNO, argc, argv, self);
    return Qnil;
}

static VALUE
recno_aref(VALUE self, VALUE key)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;
    VALUE result;
    db_recno_t recno = NUM2INT(key);

    db_key.data = &recno;
    db_key.size = sizeof(db_recno_t);
    db_value.flags = DB_DBT_MALLOC;
    db = get_db(self);
    dberr = db->get(db, NULL, &db_key, &db_value, 0);
    if (dberr == DB_NOTFOUND)
	return Qnil;
    check_bdb_error(dberr);
    result = rb_tainted_str_new(db_value.data, db_value.size);
    free(db_value.data);
    return result;
}

static VALUE
recno_aset(VALUE self, VALUE key, VALUE value)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;
    db_recno_t recno = NUM2INT(key);

    SafeStringValue(value);
    db_key.data = &recno;
    db_key.size = sizeof(db_recno_t);
    db_value.data = RSTRING(value)->ptr;
    db_value.size = RSTRING(value)->len;
    db = get_db(self);
    dberr = db->put(db, NULL, &db_key, &db_value, 0);
    check_bdb_error(dberr);
    return value;
}

static VALUE
recno_has_key(VALUE self, VALUE key)
{
    DB *db;
    DBT db_key = { 0 }, db_value = { 0 };
    int dberr;
    db_recno_t recno = NUM2INT(key);

    SafeStringValue(key);
    db_key.data = &recno;
    db_key.size = sizeof(db_recno_t);
    db_value.flags = DB_DBT_MALLOC;
    db = get_db(self);
    dberr = db->get(db, NULL, &db_key, &db_value, 0);
    if (dberr == DB_NOTFOUND)
	return Qfalse;
    check_bdb_error(dberr);
    free(db_value.data);
    return Qtrue;
}

void
Init_ximapd_bdb()
{
    VALUE mBDB, cDB, cBtree, cHash, cRecno;
    const char *version;
    int version_major, version_minor, version_patch;

    mBDB = rb_define_module("XimapdBDB");

    version = db_version(&version_major, &version_minor, &version_patch);
    rb_define_const(mBDB, "VERSION", rb_str_new2(version));
    rb_define_const(mBDB, "VERSION_MAJOR", INT2NUM(version_major));
    rb_define_const(mBDB, "VERSION_MINOR", INT2NUM(version_minor));
    rb_define_const(mBDB, "VERSION_PATCH", INT2NUM(version_patch));

    eBDBError = rb_define_class_under(mBDB, "Error", rb_eStandardError);

    cDB = rb_define_class_under(mBDB, "DB", rb_cObject);
    rb_define_alloc_func(cDB, bdb_alloc);
    rb_define_singleton_method(cDB, "open", bdb_s_open, -1);
    rb_define_method(cDB, "initialize", bdb_initialize, -1);
    rb_define_method(cDB, "close", bdb_close, 0);
    rb_define_method(cDB, "[]", bdb_aref, 1);
    rb_define_method(cDB, "[]=", bdb_aset, 2);
    rb_define_method(cDB, "has_key?", bdb_has_key, 1);
    rb_define_method(cDB, "key?", bdb_has_key, 1);
    rb_define_method(cDB, "sync", bdb_sync, 0);

    cBtree = rb_define_class_under(mBDB, "Btree", cDB);
    rb_define_method(cBtree, "initialize", btree_initialize, -1);

    cHash = rb_define_class_under(mBDB, "Hash", cDB);
    rb_define_method(cHash, "initialize", hash_initialize, -1);

    cRecno = rb_define_class_under(mBDB, "Recno", cDB);
    rb_define_method(cRecno, "initialize", recno_initialize, -1);
    rb_define_method(cRecno, "[]", recno_aref, 1);
    rb_define_method(cRecno, "[]=", recno_aset, 2);
    rb_define_method(cRecno, "has_key?", recno_has_key, 1);
    rb_define_method(cRecno, "key?", recno_has_key, 1);

    rb_define_const(mBDB, "CREATE", INT2NUM(DB_CREATE));
    rb_define_const(mBDB, "RDONLY", INT2NUM(DB_RDONLY));
    rb_define_const(mBDB, "TRUNCATE", INT2NUM(DB_TRUNCATE));
}
