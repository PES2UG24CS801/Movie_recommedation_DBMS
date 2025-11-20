-- =====================================
-- 🎬 PERSONAL MOVIE RECOMMENDER SYSTEM
-- =====================================

-- 1️⃣ Create the database
DROP DATABASE IF EXISTS movie_recommender;
CREATE DATABASE movie_recommender;
USE movie_recommender;

-- =====================================
-- 2️⃣ USERS TABLE
-- =====================================
CREATE TABLE users (
    user_id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(100) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- =====================================
-- 3️⃣ MOVIES TABLE
-- =====================================
CREATE TABLE movies (
    movie_id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(100) NOT NULL,
    genre VARCHAR(50),
    release_year INT,
    avg_rating DECIMAL(3,2) DEFAULT 0.0,
    ratings_count INT DEFAULT 0
);

-- =====================================
-- 4️⃣ RATINGS TABLE
-- =====================================
CREATE TABLE ratings (
    rating_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    movie_id INT,
    rating DECIMAL(2,1) CHECK (rating BETWEEN 0 AND 5),
    rated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    FOREIGN KEY (movie_id) REFERENCES movies(movie_id) ON DELETE CASCADE
);

-- =====================================
-- 5️⃣ RECOMMENDATIONS TABLE
-- =====================================
CREATE TABLE recommendations (
    rec_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT,
    movie_id INT,
    reason VARCHAR(255),
    recommended_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id),
    FOREIGN KEY (movie_id) REFERENCES movies(movie_id)
);

-- =====================================
-- 6️⃣ TRIGGERS: Auto-update movie ratings & counts
-- =====================================
DELIMITER $$

-- 🔹 Trigger 1: When new rating added
CREATE TRIGGER trg_after_insert_rating
AFTER INSERT ON ratings
FOR EACH ROW
BEGIN
    UPDATE movies m
    SET m.ratings_count = (
        SELECT COUNT(*) FROM ratings r WHERE r.movie_id = NEW.movie_id
    ),
    m.avg_rating = COALESCE((
        SELECT ROUND(AVG(r.rating), 2) FROM ratings r WHERE r.movie_id = NEW.movie_id
    ), 0)
    WHERE m.movie_id = NEW.movie_id;
END$$

-- 🔹 Trigger 2: When rating updated
CREATE TRIGGER trg_after_update_rating
AFTER UPDATE ON ratings
FOR EACH ROW
BEGIN
    UPDATE movies m
    SET m.ratings_count = (
        SELECT COUNT(*) FROM ratings r WHERE r.movie_id = NEW.movie_id
    ),
    m.avg_rating = COALESCE((
        SELECT ROUND(AVG(r.rating), 2) FROM ratings r WHERE r.movie_id = NEW.movie_id
    ), 0)
    WHERE m.movie_id = NEW.movie_id;
END$$

DELIMITER ;

-- =====================================
-- 7️⃣ STORED PROCEDURE: Generate Recommendations
-- =====================================
DELIMITER $$

DELIMITER $$

CREATE PROCEDURE generate_recommendations_for_user(
    IN p_user_id INT,
    IN p_limit INT
)
BEGIN
    -- Step 1: Clear old recommendations for this user
    DELETE FROM recommendations WHERE user_id = p_user_id;

    -- Step 2: Create a temporary table storing genres that user rated highly
    DROP TEMPORARY TABLE IF EXISTS user_genre_avg;
    CREATE TEMPORARY TABLE user_genre_avg AS
    SELECT 
        m.genre, 
        AVG(r.rating) AS avg_rating
    FROM ratings r
    JOIN movies m ON r.movie_id = m.movie_id
    WHERE r.user_id = p_user_id
    GROUP BY m.genre
    HAVING AVG(r.rating) >= 4.0;

    -- Step 3: Insert recommendations based on the user’s favorite genres
    INSERT INTO recommendations (user_id, movie_id, reason)
    SELECT 
        p_user_id,
        m.movie_id,
        CONCAT('Because you like ', m.genre, ' movies')
    FROM movies m
    JOIN user_genre_avg uga ON m.genre = uga.genre
    WHERE m.movie_id NOT IN (
        SELECT movie_id FROM ratings WHERE user_id = p_user_id
    )
    GROUP BY m.movie_id, m.genre, m.avg_rating
    ORDER BY m.avg_rating DESC
    LIMIT p_limit;
END$$

DELIMITER ;


-- =====================================
-- 8️⃣ SAMPLE DATA
-- =====================================
INSERT INTO users (username, email, password_hash) VALUES
('lil_milky', 'milky@example.com', 'hash1'),
('backflip', 'backflip@example.com', 'hash2'),
('neo', 'neo@matrix.com', 'hash3'),
('arya', 'arya@winterfell.com', 'hash4'),
('tony', 'tony@starkindustries.com', 'hash5'),
('joker', 'joker@gotham.com', 'hash6'),
('elsa', 'elsa@arendelle.com', 'hash7');

INSERT INTO movies (title, genre, release_year) VALUES
('Inception', 'Sci-Fi', 2010),
('The Dark Knight', 'Action', 2008),
('Interstellar', 'Sci-Fi', 2014),
('Avengers: Endgame', 'Action', 2019),
('Joker', 'Drama', 2019),
('Frozen', 'Animation', 2013),
('Parasite', 'Thriller', 2019),
('The Matrix', 'Sci-Fi', 1999),
('Iron Man', 'Action', 2008),
('Tenet', 'Sci-Fi', 2020),
('Finding Nemo', 'Animation', 2003),
('The Lion King', 'Animation', 1994),
('John Wick', 'Action', 2014),
('Black Panther', 'Action', 2018),
('Spider-Man: No Way Home', 'Action', 2021),
('The Prestige', 'Drama', 2006),
('Dune', 'Sci-Fi', 2021),
('Zootopia', 'Animation', 2016),
('Fight Club', 'Drama', 1999),
('Guardians of the Galaxy', 'Action', 2014);

INSERT INTO ratings (user_id, movie_id, rating) VALUES
(1, 1, 5), (1, 2, 4.8), (1, 3, 4.5), (1, 8, 4.7),
(2, 4, 5), (2, 9, 4.5), (2, 14, 4.6), (2, 13, 4.2),
(3, 1, 4.2), (3, 8, 5), (3, 10, 4.3), (3, 17, 4.4),
(4, 5, 4.7), (4, 19, 4.8), (4, 16, 4.5),
(5, 9, 4.9), (5, 4, 4.8), (5, 15, 4.7), (5, 20, 4.9),
(6, 5, 5), (6, 2, 4.6), (6, 13, 4.3), (6, 19, 4.5),
(7, 6, 5), (7, 11, 4.7), (7, 12, 4.6), (7, 18, 4.8);

-- =====================================
-- 9️⃣ TEST THE RECOMMENDER
-- =====================================
CALL generate_recommendations_for_user(1, 10);

SELECT r.user_id, m.title, m.genre, m.avg_rating, r.reason
FROM recommendations r
JOIN movies m ON r.movie_id = m.movie_id
WHERE r.user_id = 1
ORDER BY m.avg_rating DESC;

INSERT INTO ratings (user_id, movie_id, rating) VALUES (1, 1, 5);

SELECT title, avg_rating, ratings_count FROM movies WHERE title = 'Inception';

DELIMITER $$

CREATE PROCEDURE generate_recommendations_for_user_v2(
    IN p_user_id INT,
    IN p_limit INT
)
BEGIN
    DECLARE remaining_limit INT DEFAULT 0;

    -- 1. Clear old recs
    DELETE FROM recommendations WHERE user_id = p_user_id;

    -- 2. Build genre stats
    DROP TEMPORARY TABLE IF EXISTS user_genre_stats;
    CREATE TEMPORARY TABLE user_genre_stats AS
    SELECT UPPER(COALESCE(m.genre,'UNKNOWN')) AS genre,
           AVG(r.rating) AS avg_rating,
           COUNT(*) AS cnt
    FROM ratings r
    JOIN movies m ON r.movie_id = m.movie_id
    WHERE r.user_id = p_user_id
    GROUP BY UPPER(COALESCE(m.genre,'UNKNOWN'));

    -- 3. Check if user has ratings
    IF (SELECT COUNT(*) FROM user_genre_stats) > 0 THEN

        DROP TEMPORARY TABLE IF EXISTS top_user_genres;
        CREATE TEMPORARY TABLE top_user_genres AS
        SELECT genre
        FROM user_genre_stats
        ORDER BY avg_rating DESC, cnt DESC
        LIMIT 3;

        -- 4. Insert genre-based recs first
        INSERT INTO recommendations(user_id, movie_id, reason)
        SELECT p_user_id, m.movie_id,
               CONCAT('Because you like ', COALESCE(m.genre,'Unknown'), ' movies')
        FROM movies m
        LEFT JOIN ratings ur 
               ON ur.movie_id = m.movie_id AND ur.user_id = p_user_id
        WHERE ur.movie_id IS NULL
          AND UPPER(COALESCE(m.genre,'UNKNOWN'))
              IN (SELECT genre FROM top_user_genres)
        ORDER BY m.avg_rating DESC, m.ratings_count DESC
        LIMIT p_limit;

        -- 5. Compute remaining limit
        SET remaining_limit = p_limit - 
            (SELECT COUNT(*) FROM recommendations WHERE user_id = p_user_id);

        -- 6. Fallback if needed
        IF remaining_limit > 0 THEN
            INSERT INTO recommendations(user_id, movie_id, reason)
            SELECT p_user_id, m2.movie_id, 'Top rated fallback'
            FROM movies m2
            LEFT JOIN ratings ur2 
                   ON ur2.movie_id = m2.movie_id AND ur2.user_id = p_user_id
            WHERE ur2.movie_id IS NULL
              AND m2.movie_id NOT IN 
                  (SELECT movie_id FROM recommendations WHERE user_id = p_user_id)
            ORDER BY m2.avg_rating DESC, m2.ratings_count DESC
            LIMIT remaining_limit;
        END IF;

    ELSE
        -- No user ratings at all → pure fallback
        INSERT INTO recommendations(user_id, movie_id, reason)
        SELECT p_user_id, m.movie_id, 'Top rated fallback'
        FROM movies m
        WHERE m.movie_id NOT IN 
            (SELECT movie_id FROM ratings WHERE user_id = p_user_id)
        ORDER BY m.avg_rating DESC, m.ratings_count DESC
        LIMIT p_limit;
    END IF;

END$$

DELIMITER ;



