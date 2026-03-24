vcl 4.1;

backend default {
    .host = "app";
    .port = "80";
    .connect_timeout = 5s;
    .first_byte_timeout = 30s;
    .between_bytes_timeout = 10s;
}

sub vcl_recv {
    # Cache purge per HTTP PURGE method
    if (req.method == "PURGE") {
        return (purge);
    }

    # POST, PUT, DELETE — niekada nekešuojam
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }

    # Su auth — nekešuojam
    if (req.http.Authorization) {
        return (pass);
    }

    # Statiniai failai — visada kešuojam, ignoruojam cookies
    if (req.url ~ "\.(jpg|jpeg|png|gif|ico|webp|avif|svg|css|js|woff2?|ttf|eot|mp4|webm|pdf|zip)(\?.*)?$") {
        unset req.http.Cookie;
        return (hash);
    }

    # Uploads/media katalogas — visada kešuojam
    if (req.url ~ "^/(uploads|media|static|assets)/") {
        unset req.http.Cookie;
        return (hash);
    }

    return (hash);
}

sub vcl_backend_response {
    # Statiniai failai — kešuojam 30 dienų
    if (bereq.url ~ "\.(jpg|jpeg|png|gif|ico|webp|avif|svg|css|js|woff2?|ttf|eot|mp4|webm|pdf|zip)(\?.*)?$") {
        set beresp.ttl = 30d;
        set beresp.grace = 7d;
        unset beresp.http.Set-Cookie;
        return (deliver);
    }

    # Uploads/media — kešuojam 30 dienų
    if (bereq.url ~ "^/(uploads|media|static|assets)/") {
        set beresp.ttl = 30d;
        set beresp.grace = 7d;
        unset beresp.http.Set-Cookie;
        return (deliver);
    }

    # HTML — trumpas cache su grace
    if (beresp.http.Content-Type ~ "text/html") {
        set beresp.ttl = 5m;
        set beresp.grace = 1h;
    }

    # Backend klaida — serviruojam seną versiją jei turim
    if (beresp.status >= 500) {
        set beresp.ttl = 0s;
        set beresp.grace = 1h;
        return (restart);
    }
}

sub vcl_deliver {
    # Debug headeris — ar iš cache ar ne
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT (" + obj.hits + ")";
    } else {
        set resp.http.X-Cache = "MISS";
    }
}
