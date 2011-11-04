// TODO
// valに指定されたzero_typeを正しく0x00にエスケープする
mapping sockets = ([]);
Thread.Mutex openindex;

constant util = .HandlerSocket_util;

#ifdef DEBUG_HSOCKET
#  define DWERR(X) werror(X)
#else
#  define DWERR(X)
#endif

string _sprintf() {
	return sprintf("HandlerSocket: %O",sockets);
}

void create (string host, int port, int|void rwport) {
	Stdio.File sock = Stdio.File();
	if (!sock->connect(host,port)) {
		werror("Can't connect to socket %s:%d\n",host,port);
		sock = 0;
		return;
	}
	sockets["r"] = (["socket":sock, "indexids":({0}), "is_active": ({1}), "mutex":Thread.Mutex()]);
	if (rwport) {
		Stdio.File sockrw = Stdio.File();
		if (!sockrw->connect(host,rwport)) {
			werror("Can't connect to RW socket %s:%d\n",host,rwport);
			sockrw = 0;
			return;
		}
		sockets["w"] = (["socket":sockrw, "indexids":({0}), "is_active": ({1}), "mutex":Thread.Mutex()]);
	}
	DWERR(sprintf("Socket status: %O\n",sockets));
}

class OpenIndex {
	mapping schema;
	int indexid;
	string rwmode;
	mapping this_sock;

	string _sprintf() {
		return sprintf("HandlerSocket::OpenIndex(%O:%d) %O",rwmode,indexid,schema);
	}
	// schema ([
	//   dbname:  MUST
	//   tablename:  MUST
	//   indexname:  MAY(default "PRIMARY")
	//   columns: array(string)
	//   fcolumns: array(string)
	// ]);
	void create(mapping _schema,string|void mode) {
		if (!zero_type(mode) && mode == "w") {
			rwmode = "w";
		} else {
			rwmode = "r";
		}
		schema = copy_value(_schema);
		schema["indexname"] = schema["indexname"] || "PRIMARY";
		indexid = store_or_retrieve_open_index(rwmode,schema);
		if (open_index(rwmode,indexid,schema)) {
			this_sock = sockets[rwmode];
			return;
		}
		indexid = 0;
		schema = 0;
		rwmode = 0;
	}

	array execute_find(string op,array vals, array|void limit, array|void in,
	                   array(mapping)|mapping|void filter) {
		array resp = execute_find_or_mod_op(op,vals,limit,in,filter);
		return util.split_result_array(resp);
	}

	array execute_find_modify(string op,array vals, array|void limit, array|void in,
	                          array(mapping)|mapping|void filter, string|void mop, array|void mvals) {
		if (!limit)
			limit = ({0,0});
		array resp = execute_find_or_mod_op(op,vals,limit,in,filter,mop,mvals);
		if (mop[-1] == '?') {
			return util.split_result_array(resp);
		} else {
			return resp;
		}
	}

	private array execute_find_or_mod_op(string op, array vals, array|void limit,array|void in,
	                                     array(mapping)|mapping|void filter, string|void mop, array|void mvals ) {
		if (!indexid)
			return 0;
		array sends = create_find_or_mod_message(op,vals,limit,in,filter,mop,mvals);
		DWERR(sprintf("Sending: %O\n",sends));
		Thread.MutexKey mutex = this_sock->mutex->lock();
		util.send_data(this_sock->socket,sends);
		array res = util.get_reply(this_sock->socket);
		destruct(mutex);
		if (arrayp(res) && res[0] == "0") {
			return res;
		} else {
			werror("Response error: %O\n",res);
			return 0;
		}
	}

	array create_find_or_mod_message(string op, array vals, array|void limit,array|void in,
	                                 array(mapping)|mapping|void filter, string|void mop, array|void mvals) {
		array sends = ({(string)indexid,op});
		sends += util.array_format(util.escape_array(vals));
		if (limit)
			sends += (array(string))limit;
		if (in && sizeof(in)) {
			sends += ({ "@",in[0],
			            util.array_format( util.escape_array( in[1..] ) )
			});
		}
		if (filter) {
			foreach(Array.arrayify(filter);; mapping this_filter) {
				sends += ({
					this_filter->type,
					this_filter->op,
					(string)this_filter->col,
					(string)this_filter->val,
				});
			}
		}
		if (mop && mvals) {
			sends += ({ mop }) + util.escape_array(mvals);
		}
		return sends;
	}

	/// Only for testing.  Streaming request test.
	void execute_find_or_mod_op_onlysend(string op, array vals, array|void limit,array|void in,
	                                     array(mapping)|mapping|void filter, string|void mop, array|void mvals ) {
		if (!indexid)
			return 0;
		array sends = create_find_or_mod_message(op,vals,limit,in,filter,mop,mvals);
		DWERR(sprintf("Sending: %O\n",sends));
		util.send_data(this_sock->socket,sends);
	}

	void wait_response() {
		while(1) {
			werror("%O\n",util.get_reply(this_sock->socket));
		}
	}
	// Only for testing end

	int insert(array vals) {
		array sends = ({ (string)indexid,"+" });
		sends += util.array_format(util.escape_array(Array.flatten(vals)));
		Thread.MutexKey mutex = this_sock->mutex->lock();
		util.send_data(this_sock->socket,sends);
		array res = util.get_reply(this_sock->socket);
		destruct(mutex);
		if (res[0] == "0" && res[1] == "1")
			return 1;
		return 0;
	}
}

// TODO: More precise logic needed;
int store_or_retrieve_open_index (string rwmode,mapping schema) {
	foreach (sockets[rwmode]->indexids;int i;mapping s) {
		if (s && equal(schema,s))
			return i;
		else if (! sockets[rwmode]->is_active[i] ) {
			sockets[rwmode]->indexids[i] = schema;
			return i;
		}
	}
	sockets[rwmode]->indexids += ({ schema });
	sockets[rwmode]->is_active += ({ 0 });
	return sizeof(sockets[rwmode]->indexids) - 1;
}

int open_index(string rwmode,int indexid,mapping schema) {
	if (sockets[rwmode]->is_active[indexid])
		return indexid;
	array open_def = ({"P",(string)indexid,schema->dbname, schema->tablename, schema->indexname});
	open_def += ({ schema->columns * "," });
	if (!zero_type(schema["fcolumns"])) {
		open_def += ({ schema->fcolumns * "," });
	}
	DWERR(sprintf("Sending: %O %O\n",sockets[rwmode]->socket,open_def));
	Thread.MutexKey mutex = sockets[rwmode]->mutex->lock();
	util.send_data_escape(sockets[rwmode]->socket,open_def);
	array res = util.get_reply(sockets[rwmode]->socket);
	destruct(mutex);
	if (res && res[0] == "0" && res[1] == "1") {// Open success
		sockets[rwmode]->is_active[indexid] = 1;
		return indexid;
	} else {
		sockets[rwmode]->is_active[indexid] = 0;
		return 0;
	}
}