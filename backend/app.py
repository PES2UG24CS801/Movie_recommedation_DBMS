# backend/app.py
import os
from flask import Flask, render_template, redirect, url_for, request, flash, session, jsonify
from config import Config
from models import db, User, Movie, Rating
from werkzeug.security import generate_password_hash, check_password_hash
from sqlalchemy import text

def create_app():
    app = Flask(__name__, template_folder="templates", static_folder="static")
    app.config.from_object(Config)
    db.init_app(app)

    # Ensure DB tables exist
    with app.app_context():
        try:
            db.create_all()
        except Exception as e:
            print("⚠️ DB create_all warning:", e)

    # ---------------- HOME ----------------
    @app.route("/")
    def home():
        movies = Movie.query.order_by(Movie.avg_rating.desc()).limit(12).all()
        genres = [g[0] for g in db.session.query(Movie.genre).distinct().all() if g[0]]
        return render_template("index.html", movies=movies, genres=genres)

    # ---------------- REGISTER ----------------
    @app.route("/register", methods=["GET", "POST"])
    def register():
        if request.method == "POST":
            username = request.form.get("username")
            email = request.form.get("email")
            password = request.form.get("password")

            if not username or not email or not password:
                flash("Please fill all fields", "danger")
                return redirect(url_for("register"))

            pwd_hash = generate_password_hash(password)

            try:
                with db.engine.begin() as conn:
                    conn.execute(text(
                        "CALL sp_register_user(:username, :email, :pwd_hash, @out_user_id, @out_err);"
                    ), {"username": username, "email": email, "pwd_hash": pwd_hash})

                    out = conn.execute(text(
                        "SELECT @out_user_id AS user_id, @out_err AS errmsg;"
                    )).fetchone()

                    if out and out["errmsg"] is None:
                        flash("Registered! Please login.", "success")
                        return redirect(url_for("login"))

                    errmsg = out["errmsg"]
                    if errmsg == "username_exists":
                        flash("Username already exists", "danger")
                    elif errmsg == "email_exists":
                        flash("Email already exists", "danger")
                    else:
                        flash(f"Registration failed: {errmsg}", "danger")

            except Exception as e:
                print("Stored proc failed:", e)

                if User.query.filter((User.username == username) | (User.email == email)).first():
                    flash("User already exists", "danger")
                    return redirect(url_for("register"))

                u = User(username=username, email=email, password_hash=pwd_hash)
                db.session.add(u)
                db.session.commit()

                flash("Registered (fallback). Please login.", "success")
                return redirect(url_for("login"))

        return render_template("register.html")

    # ---------------- LOGIN ----------------
    @app.route("/login", methods=["GET", "POST"])
    def login():
        if request.method == "POST":
            name = request.form.get("username")
            password = request.form.get("password")

            if not name or not password:
                flash("Please fill all fields", "danger")
                return redirect(url_for("login"))

            try:
                with db.engine.connect() as conn:
                    res = conn.execute(text(
                        "CALL sp_get_user_by_name_or_email(:ne);"
                    ), {"ne": name})

                    row = res.fetchone()
                    if not row or not check_password_hash(row["password_hash"], password):
                        flash("Invalid credentials", "danger")
                        return redirect(url_for("login"))

                    session["user_id"] = int(row["user_id"])
                    session["username"] = row["username"]

                    flash(f"Welcome back, {row['username']}!", "success")
                    return redirect(url_for("home"))

            except Exception as e:
                print("Proc login failed:", e)

                u = User.query.filter((User.username == name) | (User.email == name)).first()

                if not u or not check_password_hash(u.password_hash, password):
                    flash("Invalid credentials", "danger")
                    return redirect(url_for("login"))

                session["user_id"] = u.user_id
                session["username"] = u.username

                flash(f"Welcome back, {u.username}!", "success")
                return redirect(url_for("home"))

        return render_template("login.html")

    # ---------------- LOGOUT ----------------
    @app.route("/logout")
    def logout():
        session.clear()
        flash("Logged out", "info")
        return redirect(url_for("home"))

    # ---------------- MOVIES PAGE ----------------
    @app.route("/movies")
    def movies():
        genre = request.args.get("genre")
        q = Movie.query

        if genre:
            q = q.filter_by(genre=genre)

        movies = q.order_by(Movie.avg_rating.desc()).all()
        genres = [g[0] for g in db.session.query(Movie.genre).distinct().all() if g[0]]

        return render_template("movies.html", movies=movies, genres=genres, selected_genre=genre)

    # ---------------- RATE MOVIE ----------------
    @app.route("/rate", methods=["POST"])
    def rate():
        if "user_id" not in session:
            return jsonify({"error": "not authenticated"}), 401

        user_id = session["user_id"]
        movie_id = request.form.get("movie_id")
        rating_val = request.form.get("rating")

        if not movie_id or not rating_val:
            return jsonify({"error": "missing fields"}), 400

        try:
            movie_id_int = int(movie_id)
            rating_val = float(rating_val)
        except:
            return jsonify({"error": "invalid rating or movie id"}), 400

        if not (0 <= rating_val <= 5):
            return jsonify({"error": "rating out of range"}), 400

        r = Rating.query.filter_by(user_id=user_id, movie_id=movie_id_int).first()

        if r:
            r.rating = rating_val
        else:
            db.session.add(Rating(user_id=user_id, movie_id=movie_id_int, rating=rating_val))

        db.session.commit()

        # --- UPDATE MOVIE AGGREGATES ---
        try:
            with db.engine.begin() as conn:
                conn.execute(text("""
                    UPDATE movies m
                    SET 
                        m.ratings_count = (SELECT COUNT(*) FROM ratings r WHERE r.movie_id = :mid),
                        m.avg_rating = COALESCE((SELECT ROUND(AVG(r.rating), 2) FROM ratings r WHERE r.movie_id = :mid), 0)
                    WHERE m.movie_id = :mid;
                """), {"mid": movie_id_int})
        except Exception as e:
            print("Aggregate update failed:", e)

        # --- NEW: AUTO-GENERATE RECOMMENDATIONS AFTER RATING ---
        try:
            with db.engine.begin() as conn:
                conn.execute(text(
                    "CALL generate_recommendations_for_user_v2(:uid, :limit);"
                ), {"uid": user_id, "limit": 15})
        except Exception as e:
            print("⚠️ Auto-recommendation update failed:", e)

        return jsonify({"ok": True})

    # ---------------- MAIN RECOMMENDATIONS ----------------
    @app.route("/recommendations")
    def recommendations():
        if "user_id" not in session:
            flash("Login to see recommendations", "warning")
            return redirect(url_for("login"))

        user_id = session["user_id"]
        limit = int(request.args.get("limit", 20))

        try:
            with db.engine.begin() as conn:
                conn.execute(text(
                    "CALL generate_recommendations_for_user_v2(:uid, :limit);"
                ), {"uid": user_id, "limit": limit})

                res = conn.execute(text("""
                    SELECT r.user_id, m.movie_id, m.title, m.genre, m.avg_rating, 
                           m.poster_path, r.reason
                    FROM recommendations r 
                    JOIN movies m ON r.movie_id = m.movie_id
                    WHERE r.user_id = :uid
                    ORDER BY m.avg_rating DESC;
                """), {"uid": user_id})

                recs = [dict(row) for row in res]

        except Exception as e:
            print("Recommendation proc failed:", e)

            sub = db.session.query(Rating.movie_id).filter(Rating.user_id == user_id).subquery()
            movies_fallback = (
                Movie.query
                .filter(~Movie.movie_id.in_(sub))
                .order_by(Movie.avg_rating.desc())
                .limit(limit)
                .all()
            )

            recs = [{
                "user_id": user_id,
                "movie_id": m.movie_id,
                "title": m.title,
                "genre": m.genre,
                "avg_rating": float(m.avg_rating or 0),
                "poster_path": m.poster_path,
                "reason": "Top rated fallback"
            } for m in movies_fallback]

        return render_template("recommendations.html", recs=recs)

    # ---------------- CUSTOM RECOMMENDATION PAGE ----------------
    @app.route("/custom_recommendations")
    def custom_recommendations():
        if "user_id" not in session:
            flash("Login to access custom recommendations", "warning")
            return redirect(url_for("login"))

        with db.engine.connect() as conn:
            res = conn.execute(text("""
                SELECT r.user_id, m.movie_id, m.title, m.genre, 
                       m.avg_rating, m.poster_path, r.reason
                FROM recommendations r
                JOIN movies m ON r.movie_id = m.movie_id
                WHERE r.user_id = :uid
                ORDER BY m.avg_rating DESC;
            """), {"uid": session["user_id"]})

        movies = [dict(row._mapping) for row in res]
        return render_template("custom_recomm.html", movies=movies)

    # ---------------- API MOVIE ----------------
    @app.route("/api/movie/<int:movie_id>")
    def api_movie(movie_id):
        m = Movie.query.get(movie_id)
        if not m:
            return jsonify({"error": "not found"}), 404

        return jsonify({
            "movie_id": m.movie_id,
            "title": m.title,
            "genre": m.genre,
            "avg_rating": float(m.avg_rating or 0),
            "ratings_count": m.ratings_count,
            "poster_path": m.poster_path
        })

    return app


if __name__ == "__main__":
    app = create_app()
    app.secret_key = app.config["SECRET_KEY"]
    app.run(debug=(os.getenv("FLASK_ENV") == "development"))
