"""Note d'immobilisation MINEXX, servie en ligne et reliée au charroi."""
import json
import os
import re
from datetime import date
from http.cookiejar import CookieJar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import HTTPCookieProcessor, HTTPRedirectHandler, Request, build_opener

ROOT = os.path.dirname(os.path.abspath(__file__))
INDEX = os.path.join(ROOT, "index.html")
SESSIONS = {}


class MinexxError(Exception):
    pass


def clean_cell(html):
    text = re.sub(r"<[^>]+>", " ", html)
    text = (
        text.replace("&nbsp;", " ")
        .replace("&amp;", "&")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&#39;", "'")
        .replace("&quot;", '"')
    )
    return re.sub(r"\s+", " ", text).strip()


class _Redirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return Request(newurl, headers={"Referer": req.full_url})


def opener_for(jar):
    return build_opener(_Redirect, HTTPCookieProcessor(jar))


def fetch(opener, url, data=None, referer=None, timeout=25):
    headers = {"User-Agent": "Minexx-Immobilisation"}
    if referer:
        headers["Referer"] = referer
    body = None
    if data is not None:
        body = urlencode(data).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    request = Request(url, data=body, headers=headers)
    try:
        response = opener.open(request, timeout=timeout)
    except HTTPError as exc:
        raw = exc.read().decode("utf-8", "replace")
        return exc.geturl(), raw, exc.code
    except URLError as exc:
        raise MinexxError(f"Minexx ne répond pas : {exc.reason}") from exc
    raw = response.read().decode("utf-8", "replace")
    return response.geturl(), raw, response.status


def csrf_token(html):
    match = re.search(r'name="csrfmiddlewaretoken" value="([^"]+)"', html)
    return match.group(1) if match else ""


def connect(base_url, username, password):
    if not base_url:
        raise MinexxError("Indiquez l'adresse Railway du charroi.")
    if not username or not password:
        raise MinexxError("Indiquez le nom d'utilisateur et le mot de passe du charroi.")
    base = base_url.strip().rstrip("/")
    key = (base, username)
    cached = SESSIONS.get(key)
    if cached and cached.get("password") == password:
        return cached
    jar = CookieJar()
    opener = opener_for(jar)
    try:
        _, login_html, _ = fetch(opener, base + "/login/")
    except MinexxError:
        raise MinexxError(f"Minexx ne répond pas à {base}.") from None
    token = csrf_token(login_html)
    if not token:
        raise MinexxError("La page de connexion Minexx est introuvable.")
    final_url, html, _ = fetch(
        opener,
        base + "/login/",
        data={
            "username": username,
            "password": password,
            "csrfmiddlewaretoken": token,
            "next": "/entretien/planning/",
        },
        referer=base + "/login/",
    )
    if "ne correspondent pas" in html or "/login" in final_url:
        raise MinexxError("Identifiants refusés par Minexx.")
    session = {"base": base, "opener": opener, "password": password}
    SESSIONS[key] = session
    return session


def list_vehicles(base_url, username, password):
    session = connect(base_url, username, password)
    base = session["base"]
    opener = session["opener"]
    vehicles = []
    page = 1
    while page <= 40:
        _, html, _ = fetch(opener, f"{base}/vehicules/?page={page}")
        rows = re.findall(r"(?s)<tr\b[^>]*>(.*?)</tr>", html)
        added = 0
        for row in rows:
            cells = re.findall(r"(?s)<td\b[^>]*>(.*?)</td>", row)
            if len(cells) < 4:
                continue
            immat = clean_cell(cells[0])
            if not immat or "Aucun véhicule" in immat:
                continue
            id_match = re.search(r"/vehicules/(\d+)/", cells[0])
            vehicles.append(
                {
                    "id": id_match.group(1) if id_match else immat,
                    "immatriculation": immat,
                    "marque": clean_cell(cells[1]),
                    "modele": clean_cell(cells[2]),
                    "affectation": clean_cell(cells[3]),
                    "kilometrage": None,
                }
            )
            added += 1
        if added == 0 or f"page={page + 1}" not in html:
            break
        page += 1
    return vehicles


def planning_km(payload):
    session = connect(payload.get("baseUrl"), payload.get("username"), payload.get("password"))
    base = session["base"]
    opener = session["opener"]
    vehicle_id = str(payload.get("vehiculeId") or "")
    immat = str(payload.get("immatriculation") or "")
    if not vehicle_id:
        raise MinexxError("Véhicule Minexx introuvable.")
    kilometrage = None
    kilometrage_apres = None
    try:
        _, raw, status = fetch(
            opener, f"{base}/entretien/get-vehicule-kilometrage/?vehicule_id={vehicle_id}"
        )
        if status == 200:
            data = json.loads(raw)
            if data.get("kilometrage") is not None:
                kilometrage = int(data["kilometrage"])
            if data.get("prochain_entretien_km") is not None:
                kilometrage_apres = int(data["prochain_entretien_km"]) - 4500
                if kilometrage_apres < 0:
                    kilometrage_apres = 0
    except (MinexxError, ValueError, json.JSONDecodeError):
        if kilometrage is None:
            raise MinexxError("Le planning entretien n'a pas renvoyé le kilométrage de ce véhicule.")
    try:
        _, html, _ = fetch(opener, base + "/entretien/planning/")
        for row in re.findall(r"(?s)<tr\b[^>]*>.*?</tr>", html):
            text = clean_cell(row)
            if immat and immat in text:
                nums = [int(n) for n in re.findall(r"\d{3,7}", text)]
                if nums and kilometrage is None:
                    kilometrage = nums[0]
                if len(nums) >= 2:
                    kilometrage_apres = nums[-2]
                break
    except MinexxError:
        pass
    if kilometrage is None and kilometrage_apres is None:
        raise MinexxError("Aucun kilométrage d'entretien pour ce véhicule dans le planning Minexx.")
    return {
        "ok": True,
        "kilometrage": kilometrage,
        "kilometrageApres": kilometrage_apres,
        "prochain": None if kilometrage_apres is None else kilometrage_apres + 5000,
    }


def update_planning(payload):
    session = connect(payload.get("baseUrl"), payload.get("username"), payload.get("password"))
    base = session["base"]
    opener = session["opener"]
    _, form_html, _ = fetch(opener, base + "/entretien/ajouter/")
    token = csrf_token(form_html)
    if not token:
        raise MinexxError("Formulaire d'entretien Minexx introuvable. Vérifiez que ce compte peut enregistrer un entretien.")
    jour = payload.get("date") or date.today().isoformat()
    final_url, html, _ = fetch(
        opener,
        base + "/entretien/ajouter/",
        data={
            "csrfmiddlewaretoken": token,
            "vehicule": str(payload.get("vehiculeId") or ""),
            "type_entretien": "ordinaire",
            "garage": str(payload.get("garage") or ""),
            "date_entretien": jour,
            "statut": "termine",
            "motif": str(payload.get("motif") or ""),
            "cout": "0",
            "kilometrage": str(payload.get("kilometrage") or ""),
            "kilometrage_apres": str(payload.get("kilometrageApres") or ""),
            "commentaires": "Mis à jour depuis la note d'immobilisation. Prochain entretien à +5000 km.",
            "pieces-TOTAL_FORMS": "0",
            "pieces-INITIAL_FORMS": "0",
            "pieces-MIN_NUM_FORMS": "0",
            "pieces-MAX_NUM_FORMS": "1000",
        },
        referer=base + "/entretien/ajouter/",
        timeout=30,
    )
    low = re.search(r"ne peut pas être inférieur[^<]{0,180}", html)
    if low:
        raise MinexxError(low.group(0))
    after = re.search(r"Le kilométrage après[^<]{0,120}", html)
    if after:
        raise MinexxError(after.group(0))
    if "/entretien/detail/" not in final_url and re.search(r"alert-danger|errorlist|invalid-feedback", html):
        raise MinexxError("Minexx n'a pas enregistré l'entretien. Ouvrez le planning et vérifiez les champs obligatoires.")
    return {"ok": True, "url": final_url}


class App(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        return

    def _json(self, code, obj):
        raw = json.dumps(obj, ensure_ascii=False).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        return json.loads(raw.decode("utf-8"))

    def do_GET(self):
        if self.path.split("?", 1)[0] not in ("/", "/index.html"):
            self.send_error(404)
            return
        data = open(INDEX, "rb").read()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        path = self.path.split("?", 1)[0]
        try:
            payload = self._read_json()
            if path == "/api/vehicules":
                vehicles = list_vehicles(payload.get("baseUrl"), payload.get("username"), payload.get("password"))
                self._json(200, {"ok": True, "vehicules": vehicles})
                return
            if path == "/api/planning":
                self._json(200, planning_km(payload))
                return
            if path == "/api/planning/actualiser":
                self._json(200, update_planning(payload))
                return
            self.send_error(404)
        except MinexxError as exc:
            self._json(400, {"ok": False, "error": str(exc)})
        except Exception as exc:
            self._json(400, {"ok": False, "error": str(exc)})


def main():
    port = int(os.environ.get("PORT", "47231"))
    server = ThreadingHTTPServer(("0.0.0.0", port), App)
    print(f"IMMOBILISATION http://0.0.0.0:{port}/", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
