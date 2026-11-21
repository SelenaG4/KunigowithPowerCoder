alter function private.clean(text, text)               set search_path = public;
alter function private.extract_emails(text)            set search_path = public;
alter function private.extract_urls(text)              set search_path = public;
alter function private.extract_phones(text)            set search_path = public;
alter function private.extract_address(text)           set search_path = public;
alter function private.import_parse_cost(text)         set search_path = public;
alter function private.import_parse_coverage(text)     set search_path = public;
alter function private.import_parse_eligibility(text)  set search_path = public;
