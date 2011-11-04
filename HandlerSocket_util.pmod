#ifdef DEBUG_HSOCKET_UTIL
#  define DWERR(X) werror(X)
#else
#  define DWERR(X)
#endif

array cmap_ctrl = map(enumerate(0x10),String.int2char);;
array esc_cmap_ctrl = map(cmap_ctrl,lambda(string s) { s = "\1"+s;s[-1]+=0x40; return s; });

array escape_array(array raw) {
	return map(raw,lambda(mixed x) {
		               if (zero_type(x))
			               x = "\0";
		               else if ( ! stringp(x))
			               x = (string)x;
		               return replace(x,cmap_ctrl,esc_cmap_ctrl);
	               });
}

void send_data(Stdio.File sock, array data) {
	send_array(sock,data);
}

void send_data_escape(Stdio.File sock, array raw) {
	send_array(sock,escape_array(raw));
}

array array_format(array arr) {
	return (array(string))(({sizeof(arr)}) + arr);
}

void send_array(Stdio.File sock,array data) {
	string sendd = data * "\t" + "\n";
	DWERR(sprintf("Send(%O):\n%s\n",sock,sendd));
	sock->write( sendd );
}

array get_reply(Stdio.File sock) {
	string got = read_socket(sock);
	if (!got) return 0;
	array resp_lines = got / "\n";
	DWERR(sprintf("response array %O\n",resp_lines));
	if (sizeof(resp_lines)>1 && resp_lines[-1] == "")
		resp_lines = resp_lines[0..sizeof(resp_lines)-2];
	array resp = ({});
	foreach (resp_lines;;string reply) {
		resp += ({ map(reply / "\t",replace,esc_cmap_ctrl,cmap_ctrl) });
	}
	DWERR(sprintf("Response: %O\n",resp));
	if (sizeof(resp) == 1)
		return resp[0];
	return resp;
}

string read_socket(Stdio.File sock) {
	int readbuffer = 4096;
	string buffer = "";

	int try = 10;
	while(try) {
		if (sock->peek(1)) {
			string d;
			do {
				d = sock->read(readbuffer,1);
				DWERR(sprintf("Read %d len\n",sizeof(d)));
				buffer+=d;
			} while (sizeof(d) == readbuffer || d[-1] != '\n');
			DWERR(sprintf("Got: %s\n",buffer));
			return buffer;
		} else
			try--;
	}
	DWERR(sprintf("No response from %O\n",sock));
	return 0;
}

array split_result_array(array res) {
	return res[2..] / (int)res[1];
}
