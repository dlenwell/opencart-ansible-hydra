backend default {
  .host = "127.0.0.1";
  .port = "8080";
}

acl purge {
  "localhost";
  "127.0.0.1";
  "10.10.10.0"/16;
}

acl debug {
  "localhost";
  "127.0.0.1";
  "10.10.10.0"/16;
}

sub vcl_recv {

  # if the client has no magic cookie but comes from the internal IP he gets
  # initialized (because it's his first request) and redirected (see below)
  if (req.http.cookie !~ "X-Magicdust" && client.ip == "{{ internal_office_ip }}") {
    error 750 "init-internal-traffic";
  }

  if (req.restarts == 0) {
    if (req.http.x-forwarded-for) {
      set req.http.X-Forwarded-For = req.http.X-Forwarded-For + ", " + client.ip;
    } else {
      set req.http.X-Forwarded-For = client.ip;
    }
  }

  if (
    req.request != "GET" &&
    req.request != "HEAD" &&
    req.request != "PUT" &&
    req.request != "POST" &&
    req.request != "TRACE" &&
    req.request != "OPTIONS" &&
    req.request != "DELETE" &&
    req.request != "PURGE"
  ) {
      /* Non-RFC2616 or CONNECT which is weird. */
      return (pipe);
  }

  # purge request
  if (req.request == "PURGE") {
    if (!client.ip ~ purge) {
      error 405 "Not allowed.";
    }
    ban("obj.http.X-Purge-Host ~ " + req.http.X-Purge-Host + " && obj.http.X-Purge-URL ~ " + req.http.X-Purge-Regex);
    error 200 "Purged. obj.http.X-Purge-Host ~ " + req.http.X-Purge-Host + " && obj.http.X-Purge-URL ~ " + req.http.X-Purge-Regex + " && obj.http.Content-Type ~ " + req.http.X-Purge-Content-Type;
  }

  # we only deal with GET and HEAD by default
  if (req.request != "GET" && req.request != "HEAD") {
    return (pass);
  }

  # normalize url in case of leading HTTP scheme and domain
  set req.url = regsub(req.url, "^http[s]?://[^/]+", "");

  # static files are always cacheable. remove SSL flag and cookie
  if (req.url ~ "^/(media|js|skin)/.*\.(png|jpg|jpeg|gif|css|js|swf|ico)$") {
    unset req.http.Https;
    unset req.http.Cookie;
  }

  # not cacheable by default
  if (req.http.Authorization || req.http.Https) {
    return (pass);
  }
  if (req.url ~ "/feed") {
    return (pass);
  }

  # do not cache any page from
  # - index files
  # - ajaxUpdate-calls
  # - ...
  # if (req.url ~ "^/(index)" || req.url ~ "ajax") {
  if (req.url ~ "^/(index)" || req.url ~ "ajax" || req.url ~ "/nginx_status" || req.url ~ "/fpm_status" || req.url ~ "/checkout") {
    return (pass);
  }

  # as soon as we have a NOCACHE cookie pass request
  if (req.http.cookie ~ "NOCACHE=") {
    return (pass);
  }

  # normalize Accept-Encoding header
  # http://varnish.projects.linpro.no/wiki/FAQ/Compression
  if (req.http.Accept-Encoding) {
    if (req.url ~ "\.(jpg|png|gif|gz|tgz|bz2|tbz|mp3|ogg|swf|flv)$") {
      # No point in compressing these
      remove req.http.Accept-Encoding;
    } elsif (req.http.Accept-Encoding ~ "gzip") {
      set req.http.Accept-Encoding = "gzip";
    } elsif (req.http.Accept-Encoding ~ "deflate" && req.http.user-agent !~ "MSIE") {
      set req.http.Accept-Encoding = "deflate";
    } else {
      # unkown algorithm
      remove req.http.Accept-Encoding;
    }
  }

  # remove Google gclid parameters
  set req.url = regsuball(req.url,"\?gclid=[^&]+$","");   # strips when QS = "?gclid=AAA"
  set req.url = regsuball(req.url,"\?gclid=[^&]+&","?");  # strips when QS = "?gclid=AAA&foo=bar"
  set req.url = regsuball(req.url,"&gclid=[^&]+","");     # strips when QS = "?foo=bar&gclid=AAA" or QS = "?foo=bar&gclid=AAA&bar=baz"

  return (lookup);
}

sub vcl_hash {
  hash_data(req.url);
  if (req.http.host) {
    hash_data(req.http.host);
  } else {
    hash_data(server.ip);
  }
  if (!(req.url ~ "^/(media|js|skin)/.*\.(png|jpg|jpeg|gif|css|js|swf|ico)$")) {
    call design_exception;
  }
  return (hash);
}

sub vcl_fetch {

  if (beresp.status == 500) {
   set beresp.saintmode = 10s;
   return (restart);
  }

  if (beresp.status == 404) {
    return (hit_for_pass);
  }

  set beresp.grace = 5m;

  # add ban-lurker tags to object
  set beresp.http.X-Purge-URL = req.url;
  set beresp.http.X-Purge-Host = req.http.host;

  if (beresp.status == 200 || beresp.status == 301) {
    if (beresp.http.Content-Type ~ "text/html" || beresp.http.Content-Type ~ "text/xml") {
      if ((beresp.http.Set-Cookie ~ "NO_CACHE=") || (beresp.ttl < 1s)) {
        set beresp.ttl = 0s;
        return (hit_for_pass);
      }

      # marker for vcl_deliver to reset Age:
      set beresp.http.magicmarker = "1";

      # Don't cache cookies
      unset beresp.http.set-cookie;

    } else {
      # set default TTL value for static content
      set beresp.ttl = 4h;
    }
    return (deliver);
  }

  return (hit_for_pass);
}

sub vcl_deliver {
  # debug info
  if (resp.http.X-Cache-Debug || client.ip ~ debug) {
    if (obj.hits > 0) {
      set resp.http.X-Cache = "HIT";
      set resp.http.X-Cache-Hits = obj.hits;
    } else {
      set resp.http.X-Cache = "MISS";
    }
    set resp.http.X-Cache-Expires = resp.http.Expires;
  } else {
    # remove Varnish/proxy header
    remove resp.http.X-Varnish;
    remove resp.http.Via;
    remove resp.http.Age;
    remove resp.http.X-Purge-URL;
    remove resp.http.X-Purge-Host;
  }

  if (resp.http.magicmarker) {
    # Remove the magic marker
    unset resp.http.magicmarker;

    set resp.http.Cache-Control = "no-store, no-cache, must-revalidate, post-check=0, pre-check=0";
    set resp.http.Pragma = "no-cache";
    set resp.http.Expires = "Mon, 31 Mar 2008 10:00:00 GMT";
    set resp.http.Age = "0";
  }

}

sub vcl_error {

  # internal initialization uses 750 error code
  if (obj.status == 750) {

    # initialize client with magic cookie
    set obj.http.Set-Cookie = "X-Magicdust=1;path=/;";

    # redirect client to the same url
    set obj.http.Location = "http://" + req.http.Host + req.url;
    set obj.status = 302;

    return(deliver);

  # default error handling
  } else {

    set obj.http.Content-Type = "text/html; charset=utf-8";
    set obj.http.Retry-After = "5";
    synthetic {"
  <?xml version="1.0" encoding="utf-8"?>
  <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Strict//EN"
   "http://www.w3.org/TR/xhtml1/DTD/xhtml1-strict.dtd">
  <html>
    <head>
      <title>"} + obj.status + " " + obj.response + {"</title>
    </head>
    <body>
      <h1>Error "} + obj.status + " " + obj.response + {"</h1>
      <p>"} + obj.response + {"</p>
      <h3>Guru Meditation:</h3>
      <p>XID: "} + req.xid + {"</p>
      <hr>
      <p>Varnish cache server</p>
    </body>
  </html>
  "};
    return (deliver);
  }
}

sub design_exception {

}
