-- Copyright (C) 2011-2014 Kim Alvefur
--
-- This project is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.
--

-- TODO
-- Fix folding.

local st = require "util.stanza";
local t_insert, t_concat = table.insert, table.concat;
local type = type;
local pairs, ipairs = pairs, ipairs;

local from_text, to_text, from_xep54, to_xep54;

local line_sep = "\n";

local vCard_dtd; -- See end of file
local vCard4_dtd;

local function vCard_esc(s)
	return s:gsub("[,:;\\]", "\\%1"):gsub("\n","\\n");
end

local function vCard_unesc(s)
	return s:gsub("\\?[\\nt:;,]", {
		["\\\\"] = "\\",
		["\\n"] = "\n",
		["\\r"] = "\r",
		["\\t"] = "\t",
		["\\:"] = ":", -- FIXME Shouldn't need to escape : in values, just params
		["\\;"] = ";",
		["\\,"] = ",",
		[":"] = "\29",
		[";"] = "\30",
		[","] = "\31",
	});
end

local function item_to_xep54(item)
	local t = st.stanza(item.name, { xmlns = "vcard-temp" });

	local prop_def = vCard_dtd[item.name];
	if prop_def == "text" then
		t:text(item[1]);
	elseif type(prop_def) == "table" then
		if prop_def.types and item.TYPE then
			if type(item.TYPE) == "table" then
				for _,v in pairs(prop_def.types) do
					for _,typ in pairs(item.TYPE) do
						if typ:upper() == v then
							t:tag(v):up();
							break;
						end
					end
				end
			else
				t:tag(item.TYPE:upper()):up();
			end
		end

		if prop_def.props then
			for _,prop in pairs(prop_def.props) do
				if item[prop] then
					for _, v in ipairs(item[prop]) do
						t:text_tag(prop, v);
					end
				end
			end
		end

		if prop_def.value then
			t:text_tag(prop_def.value, item[1]);
		elseif prop_def.values then
			local prop_def_values = prop_def.values;
			local repeat_last = prop_def_values.behaviour == "repeat-last" and prop_def_values[#prop_def_values];
			for i=1,#item do
				t:text_tag(prop_def.values[i] or repeat_last, item[i]);
			end
		end
	end

	return t;
end

local function vcard_to_xep54(vCard)
	local t = st.stanza("vCard", { xmlns = "vcard-temp" });
	for i=1,#vCard do
		t:add_child(item_to_xep54(vCard[i]));
	end
	return t;
end

function to_xep54(vCards)
	if not vCards[1] or vCards[1].name then
		return vcard_to_xep54(vCards)
	else
		local t = st.stanza("xCard", { xmlns = "vcard-temp" });
		for i=1,#vCards do
			t:add_child(vcard_to_xep54(vCards[i]));
		end
		return t;
	end
end

function from_text(data)
	data = data -- unfold and remove empty lines
		:gsub("\r\n","\n")
		:gsub("\n ", "")
		:gsub("\n\n+","\n");
	local vCards = {};
	local current;
	for line in data:gmatch("[^\n]+") do
		line = vCard_unesc(line);
		local name, params, value = line:match("^([-%a]+)(\30?[^\29]*)\29(.*)$");
		value = value:gsub("\29",":");
		if #params > 0 then
			local _params = {};
			for k,isval,v in params:gmatch("\30([^=]+)(=?)([^\30]*)") do
				k = k:upper();
				local _vt = {};
				for _p in v:gmatch("[^\31]+") do
					_vt[#_vt+1]=_p
					_vt[_p]=true;
				end
				if isval == "=" then
					_params[k]=_vt;
				else
					_params[k]=true;
				end
			end
			params = _params;
		end
		if name == "BEGIN" and value == "VCARD" then
			current = {};
			vCards[#vCards+1] = current;
		elseif name == "END" and value == "VCARD" then
			current = nil;
		elseif current and vCard_dtd[name] then
			local dtd = vCard_dtd[name];
			local item = { name = name };
			t_insert(current, item);
			local up = current;
			current = item;
			if dtd.types then
				for _, t in ipairs(dtd.types) do
					t = t:lower();
					if ( params.TYPE and params.TYPE[t] == true)
							or params[t] == true then
						current.TYPE=t;
					end
				end
			end
			if dtd.props then
				for _, p in ipairs(dtd.props) do
					if params[p] then
						if params[p] == true then
							current[p]=true;
						else
							for _, prop in ipairs(params[p]) do
								current[p]=prop;
							end
						end
					end
				end
			end
			if dtd == "text" or dtd.value then
				t_insert(current, value);
			elseif dtd.values then
				for p in ("\30"..value):gmatch("\30([^\30]*)") do
					t_insert(current, p);
				end
			end
			current = up;
		end
	end
	return vCards;
end

local function item_to_text(item)
	local value = {};
	for i=1,#item do
		value[i] = vCard_esc(item[i]);
	end
	value = t_concat(value, ";");

	local params = "";
	for k,v in pairs(item) do
		if type(k) == "string" and k ~= "name" then
			params = params .. (";%s=%s"):format(k, type(v) == "table" and t_concat(v,",") or v);
		end
	end

	return ("%s%s:%s"):format(item.name, params, value)
end

local function vcard_to_text(vcard)
	local t={};
	t_insert(t, "BEGIN:VCARD")
	for i=1,#vcard do
		t_insert(t, item_to_text(vcard[i]));
	end
	t_insert(t, "END:VCARD")
	return t_concat(t, line_sep);
end

function to_text(vCards)
	if vCards[1] and vCards[1].name then
		return vcard_to_text(vCards)
	else
		local t = {};
		for i=1,#vCards do
			t[i]=vcard_to_text(vCards[i]);
		end
		return t_concat(t, line_sep);
	end
end

local function from_xep54_item(item)
	local prop_name = item.name;
	local prop_def = vCard_dtd[prop_name];

	local prop = { name = prop_name };

	if prop_def == "text" then
		prop[1] = item:get_text();
	elseif type(prop_def) == "table" then
		if prop_def.value then --single item
			prop[1] = item:get_child_text(prop_def.value) or "";
		elseif prop_def.values then --array
			local value_names = prop_def.values;
			if value_names.behaviour == "repeat-last" then
				for i=1,#item.tags do
					t_insert(prop, item.tags[i]:get_text() or "");
				end
			else
				for i=1,#value_names do
					t_insert(prop, item:get_child_text(value_names[i]) or "");
				end
			end
		elseif prop_def.names then
			local names = prop_def.names;
			for i=1,#names do
				if item:get_child(names[i]) then
					prop[1] = names[i];
					break;
				end
			end
		end

		if prop_def.props_verbatim then
			for k,v in pairs(prop_def.props_verbatim) do
				prop[k] = v;
			end
		end

		if prop_def.types then
			local types = prop_def.types;
			prop.TYPE = {};
			for i=1,#types do
				if item:get_child(types[i]) then
					t_insert(prop.TYPE, types[i]:lower());
				end
			end
			if #prop.TYPE == 0 then
				prop.TYPE = nil;
			end
		end

		-- A key-value pair, within a key-value pair?
		if prop_def.props then
			local params = prop_def.props;
			for i=1,#params do
				local name = params[i]
				local data = item:get_child_text(name);
				if data then
					prop[name] = prop[name] or {};
					t_insert(prop[name], data);
				end
			end
		end
	else
		return nil
	end

	return prop;
end

local function from_xep54_vCard(vCard)
	local tags = vCard.tags;
	local t = {};
	for i=1,#tags do
		t_insert(t, from_xep54_item(tags[i]));
	end
	return t
end

function from_xep54(vCard)
	if vCard.attr.xmlns ~= "vcard-temp" then
		return nil, "wrong-xmlns";
	end
	if vCard.name == "xCard" then -- A collection of vCards
		local t = {};
		local vCards = vCard.tags;
		for i=1,#vCards do
			t[i] = from_xep54_vCard(vCards[i]);
		end
		return t
	elseif vCard.name == "vCard" then -- A single vCard
		return from_xep54_vCard(vCard)
	end
end

local vcard4 = { }

function vcard4:text(node, params, value) -- luacheck: ignore 212/params
	self:tag(node:lower())
	-- FIXME params
	if type(value) == "string" then
		self:text_tag("text", value);
	elseif vcard4[node] then
		vcard4[node](value);
	end
	self:up();
end

function vcard4.N(value)
	for i, k in ipairs(vCard_dtd.N.values) do
		value:text_tag(k, value[i]);
	end
end

local xmlns_vcard4 = "urn:ietf:params:xml:ns:vcard-4.0"

local function item_to_vcard4(item)
	local typ = item.name:lower();
	local t = st.stanza(typ, { xmlns = xmlns_vcard4 });

	local prop_def = vCard4_dtd[typ];
	if prop_def == "text" then
		t:text_tag("text", item[1]);
	elseif prop_def == "uri" then
		if item.ENCODING and item.ENCODING[1] == 'b' then
			t:text_tag("uri", "data:;base64," .. item[1]);
		else
			t:text_tag("uri", item[1]);
		end
	elseif type(prop_def) == "table" then
		if prop_def.values then
			for i, v in ipairs(prop_def.values) do
				t:text_tag(v:lower(), item[i]);
			end
		else
			t:tag("unsupported",{xmlns="http://zash.se/protocol/vcardlib"})
		end
	else
		t:tag("unsupported",{xmlns="http://zash.se/protocol/vcardlib"})
	end
	return t;
end

local function vcard_to_vcard4xml(vCard)
	local t = st.stanza("vcard", { xmlns = xmlns_vcard4 });
	for i=1,#vCard do
		t:add_child(item_to_vcard4(vCard[i]));
	end
	return t;
end

local function vcards_to_vcard4xml(vCards)
	if not vCards[1] or vCards[1].name then
		return vcard_to_vcard4xml(vCards)
	else
		local t = st.stanza("vcards", { xmlns = xmlns_vcard4 });
		for i=1,#vCards do
			t:add_child(vcard_to_vcard4xml(vCards[i]));
		end
		return t;
	end
end

-- This was adapted from http://xmpp.org/extensions/xep-0054.html#dtd
vCard_dtd = {
	VERSION = "text", --MUST be 3.0, so parsing is redundant
	FN = "text",
	N = {
		values = {
			"FAMILY",
			"GIVEN",
			"MIDDLE",
			"PREFIX",
			"SUFFIX",
		},
	},
	NICKNAME = "text",
	PHOTO = {
		props_verbatim = { ENCODING = { "b" } },
		props = { "TYPE" },
		value = "BINVAL", --{ "EXTVAL", },
	},
	BDAY = "text",
	ADR = {
		types = {
			"HOME",
			"WORK",
			"POSTAL",
			"PARCEL",
			"DOM",
			"INTL",
			"PREF",
		},
		values = {
			"POBOX",
			"EXTADD",
			"STREET",
			"LOCALITY",
			"REGION",
			"PCODE",
			"CTRY",
		}
	},
	LABEL = {
		types = {
			"HOME",
			"WORK",
			"POSTAL",
			"PARCEL",
			"DOM",
			"INTL",
			"PREF",
		},
		value = "LINE",
	},
	TEL = {
		types = {
			"HOME",
			"WORK",
			"VOICE",
			"FAX",
			"PAGER",
			"MSG",
			"CELL",
			"VIDEO",
			"BBS",
			"MODEM",
			"ISDN",
			"PCS",
			"PREF",
		},
		value = "NUMBER",
	},
	EMAIL = {
		types = {
			"HOME",
			"WORK",
			"INTERNET",
			"PREF",
			"X400",
		},
		value = "USERID",
	},
	JABBERID = "text",
	MAILER = "text",
	TZ = "text",
	GEO = {
		values = {
			"LAT",
			"LON",
		},
	},
	TITLE = "text",
	ROLE = "text",
	LOGO = "copy of PHOTO",
	AGENT = "text",
	ORG = {
		values = {
			behaviour = "repeat-last",
			"ORGNAME",
			"ORGUNIT",
		}
	},
	CATEGORIES = {
		values = "KEYWORD",
	},
	NOTE = "text",
	PRODID = "text",
	REV = "text",
	SORTSTRING = "text",
	SOUND = "copy of PHOTO",
	UID = "text",
	URL = "text",
	CLASS = {
		names = { -- The item.name is the value if it's one of these.
			"PUBLIC",
			"PRIVATE",
			"CONFIDENTIAL",
		},
	},
	KEY = {
		props = { "TYPE" },
		value = "CRED",
	},
	DESC = "text",
};
vCard_dtd.LOGO = vCard_dtd.PHOTO;
vCard_dtd.SOUND = vCard_dtd.PHOTO;

vCard4_dtd = {
	source = "uri",
	kind = "text",
	xml = "text",
	fn = "text",
	n = {
		values = {
			"family",
			"given",
			"middle",
			"prefix",
			"suffix",
		},
	},
	nickname = "text",
	photo = "uri",
	bday = "date-and-or-time",
	anniversary = "date-and-or-time",
	gender = "text",
	adr = {
		values = {
			"pobox",
			"ext",
			"street",
			"locality",
			"region",
			"code",
			"country",
		}
	},
	tel = "text",
	email = "text",
	impp = "uri",
	lang = "language-tag",
	tz = "text",
	geo = "uri",
	title = "text",
	role = "text",
	logo = "uri",
	org = "text",
	member = "uri",
	related = "uri",
	categories = "text",
	note = "text",
	prodid = "text",
	rev = "timestamp",
	sound = "uri",
	uid = "uri",
	clientpidmap = "number, uuid",
	url = "uri",
	version = "text",
	key = "uri",
	fburl = "uri",
	caladruri = "uri",
	caluri = "uri",
};

return {
	from_text = from_text;
	to_text = to_text;

	from_xep54 = from_xep54;
	to_xep54 = to_xep54;

	to_vcard4 = vcards_to_vcard4xml;
};
