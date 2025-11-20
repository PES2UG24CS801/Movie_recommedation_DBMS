-- ================================
-- 🎬 MOVIE RECOMMENDER DATABASE INIT SCRIPT
-- ================================

DROP DATABASE IF EXISTS movie_recommender;
CREATE DATABASE movie_recommender;
USE movie_recommender;

-- ================================
-- 👤 USERS TABLE
-- ================================
CREATE TABLE users (
    user_id INT AUTO_INCREMENT PRIMARY KEY,
    username VARCHAR(50) UNIQUE NOT NULL,
    email VARCHAR(100) UNIQUE NOT NULL,
    password_hash VARCHAR(255) NOT NULL,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
) ENGINE=InnoDB;

-- ================================
-- 🎥 MOVIES TABLE (with poster_path)
-- ================================
CREATE TABLE movies (
    movie_id INT AUTO_INCREMENT PRIMARY KEY,
    title VARCHAR(200) NOT NULL,
    genre VARCHAR(50),
    release_year INT,
    avg_rating DECIMAL(3,2) DEFAULT 0.00,
    ratings_count INT DEFAULT 0,
    poster_path VARCHAR(255)
) ENGINE=InnoDB;

-- ================================
-- ⭐ RATINGS TABLE
-- ================================
CREATE TABLE ratings (
    rating_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    movie_id INT NOT NULL,
    rating DECIMAL(3,1) NOT NULL CHECK (rating >= 0 AND rating <= 5),
    rated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    FOREIGN KEY (movie_id) REFERENCES movies(movie_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ================================
-- 🎯 RECOMMENDATIONS TABLE
-- ================================
CREATE TABLE recommendations (
    rec_id INT AUTO_INCREMENT PRIMARY KEY,
    user_id INT NOT NULL,
    movie_id INT NOT NULL,
    reason VARCHAR(255),
    recommended_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (user_id) REFERENCES users(user_id) ON DELETE CASCADE,
    FOREIGN KEY (movie_id) REFERENCES movies(movie_id) ON DELETE CASCADE
) ENGINE=InnoDB;

-- ================================
-- 📈 INDEXES
-- ================================
CREATE INDEX idx_ratings_movie ON ratings(movie_id);
CREATE INDEX idx_movies_genre ON movies(genre);
CREATE INDEX idx_ratings_user ON ratings(user_id);

-- ================================
-- 🧮 TRIGGERS - keep movie ratings updated
-- ================================
DELIMITER $$

CREATE TRIGGER trg_after_insert_rating
AFTER INSERT ON ratings
FOR EACH ROW
BEGIN
    UPDATE movies m
    SET m.ratings_count = (SELECT COUNT(*) FROM ratings r WHERE r.movie_id = NEW.movie_id),
        m.avg_rating = COALESCE((SELECT ROUND(AVG(r.rating),2) FROM ratings r WHERE r.movie_id = NEW.movie_id), 0)
    WHERE m.movie_id = NEW.movie_id;
END$$

CREATE TRIGGER trg_after_update_rating
AFTER UPDATE ON ratings
FOR EACH ROW
BEGIN
    UPDATE movies m
    SET m.ratings_count = (SELECT COUNT(*) FROM ratings r WHERE r.movie_id = NEW.movie_id),
        m.avg_rating = COALESCE((SELECT ROUND(AVG(r.rating),2) FROM ratings r WHERE r.movie_id = NEW.movie_id), 0)
    WHERE m.movie_id = NEW.movie_id;
END$$

CREATE TRIGGER trg_after_delete_rating
AFTER DELETE ON ratings
FOR EACH ROW
BEGIN
    UPDATE movies m
    SET m.ratings_count = (SELECT COUNT(*) FROM ratings r WHERE r.movie_id = OLD.movie_id),
        m.avg_rating = COALESCE((SELECT ROUND(AVG(r.rating),2) FROM ratings r WHERE r.movie_id = OLD.movie_id), 0)
    WHERE m.movie_id = OLD.movie_id;
END$$

DELIMITER ;

-- ================================
-- 🧩 STORED PROCEDURES
-- ================================
DELIMITER $$

-- ✅ REGISTER USER PROCEDURE
CREATE PROCEDURE sp_register_user(
    IN p_username VARCHAR(50),
    IN p_email VARCHAR(100),
    IN p_password_hash VARCHAR(255),
    OUT p_user_id INT,
    OUT p_errmsg VARCHAR(255)
)
main_block: BEGIN
    DECLARE EXIT HANDLER FOR SQLEXCEPTION
    BEGIN
        ROLLBACK;
        SET p_user_id = NULL;
        SET p_errmsg = 'Unknown DB error';
    END;

    START TRANSACTION;

    IF EXISTS (SELECT 1 FROM users WHERE username = p_username) THEN
        SET p_user_id = NULL;
        SET p_errmsg = 'username_exists';
        ROLLBACK;
        LEAVE main_block;
    END IF;

    IF EXISTS (SELECT 1 FROM users WHERE email = p_email) THEN
        SET p_user_id = NULL;
        SET p_errmsg = 'email_exists';
        ROLLBACK;
        LEAVE main_block;
    END IF;

    INSERT INTO users(username, email, password_hash)
    VALUES (p_username, p_email, p_password_hash);

    SET p_user_id = LAST_INSERT_ID();
    SET p_errmsg = NULL;
    COMMIT;
END$$


-- ✅ GET USER BY NAME OR EMAIL
CREATE PROCEDURE sp_get_user_by_name_or_email(IN p_name_or_email VARCHAR(255))
BEGIN
    SELECT user_id, username, email, password_hash, created_at
    FROM users
    WHERE username = p_name_or_email OR email = p_name_or_email
    LIMIT 1;
END$$


-- ✅ GENERATE RECOMMENDATIONS (genre-based)
DELIMITER $$

DROP PROCEDURE IF EXISTS generate_recommendations_for_user$$

CREATE PROCEDURE generate_recommendations_for_user(IN p_user_id INT, IN p_limit INT)
BEGIN
    -- clear previous cache for this user
    DELETE FROM recommendations WHERE user_id = p_user_id;

    -- build temporary per-genre stats for this user
    DROP TEMPORARY TABLE IF EXISTS user_genre_avg;
    CREATE TEMPORARY TABLE user_genre_avg AS
    SELECT COALESCE(m.genre, 'Unknown') AS genre,
           AVG(r.rating) AS avg_rating,
           COUNT(*) AS cnt
    FROM ratings r
    JOIN movies m ON r.movie_id = m.movie_id
    WHERE r.user_id = p_user_id
    GROUP BY COALESCE(m.genre, 'Unknown');

    -- if user has any genre with avg >= 4.0, recommend from all such genres
    IF (SELECT COUNT(*) FROM user_genre_avg WHERE avg_rating >= 4.0) > 0 THEN
        INSERT INTO recommendations (user_id, movie_id, reason)
        SELECT DISTINCT
               p_user_id,
               m.movie_id,
               CONCAT('Because you rated many ', COALESCE(m.genre,'Unknown'), ' movies highly!')
        FROM movies m
        JOIN user_genre_avg uga ON COALESCE(m.genre,'Unknown') = uga.genre
        WHERE uga.avg_rating >= 4.0
          AND m.movie_id NOT IN (SELECT movie_id FROM ratings WHERE user_id = p_user_id)
        ORDER BY (m.avg_rating * 0.75 + COALESCE(m.ratings_count,0) * 0.01) DESC
        LIMIT p_limit;
    ELSE
        -- fallback: top globally-rated movies the user hasn't rated yet
        INSERT INTO recommendations (user_id, movie_id, reason)
        SELECT p_user_id, m.movie_id, 'Top rated fallback'
        FROM movies m
        WHERE m.movie_id NOT IN (SELECT movie_id FROM ratings WHERE user_id = p_user_id)
        ORDER BY m.avg_rating DESC, m.ratings_count DESC
        LIMIT p_limit;
    END IF;
END$$

DELIMITER ;


-- ================================
-- 🍿 SAMPLE MOVIES
-- (make sure posters exist in backend/static/posters/)
-- ================================
INSERT INTO movies (title, genre, release_year, poster_path) VALUES
('Inception','Sci-Fi',2010,'inception.jpg'),
('The Dark Knight','Action',2008,'dark_knight.jpg'),
('Interstellar','Sci-Fi',2014,'interstellar.jpg'),
('Avengers: Endgame','Action',2019,'endgame.jpg'),
('Joker','Drama',2019,'joker.jpg'),
('Frozen','Animation',2013,'frozen.jpg'),
('Parasite','Thriller',2019,'parasite.jpg'),
('The Matrix','Sci-Fi',1999,'matrix.jpg'),
('Iron Man','Action',2008,'ironman.jpg'),
('Tenet','Sci-Fi',2020,'tenet.jpg'),
('Finding Nemo','Animation',2003,'nemo.jpg'),
('The Lion King','Animation',1994,'lionking.jpg'),
('John Wick','Action',2014,'johnwick.jpg'),
('Black Panther','Action',2018,'blackpanther.jpg'),
('Spider-Man: No Way Home','Action',2021,'spiderman.jpg'),
('The Prestige','Drama',2006,'prestige.jpg'),
('Dune','Sci-Fi',2021,'dune.jpg'),
('Zootopia','Animation',2016,'zootopia.jpg'),
('Fight Club','Drama',1999,'fightclub.jpg'),
('Guardians of the Galaxy','Action',2014,'guardians.jpg');


-- 🧪 Generate IMDb-like dummy ratings for all movies
DELIMITER $$

CREATE PROCEDURE populate_dummy_ratings()
BEGIN
    DECLARE done INT DEFAULT 0;
    DECLARE mid INT;
    DECLARE cur CURSOR FOR SELECT movie_id FROM movies;
    DECLARE CONTINUE HANDLER FOR NOT FOUND SET done = 1;

    OPEN cur;
    read_loop: LOOP
        FETCH cur INTO mid;
        IF done THEN
            LEAVE read_loop;
        END IF;

        -- Add 20 to 100 dummy ratings per movie
        SET @count = FLOOR(20 + (RAND() * 80));

        WHILE @count > 0 DO
            INSERT INTO ratings(user_id, movie_id, rating)
            VALUES (
                FLOOR(1 + RAND() * 1000),     -- fake user IDs 1–1000
                mid,
                ROUND(3 + RAND() * 2, 1)      -- ratings between 3.0 and 5.0
            );
            SET @count = @count - 1;
        END WHILE;
    END LOOP;

    CLOSE cur;
END$$

DELIMITER ;

	
INSERT INTO movies (title, genre, release_year, poster_path) VALUES
 ('Oppenheimer', 'Drama', 2023, 'oppenheimer.jpg'), 
 ('The Boys', 'Action', 2019, 'boys.jpg'),
 ('Captain America', 'Action', 2025, 'captain.jpg'),
 ('Superman', 'Drama', 1992, 'superman.jpg'),
 ('Jagame Thanthiram','Action',2020,'jagame.jpg'),
 ('Vishvaroopam','Action',2013,'kamal.jpg'),
 ('Dune: Part Two', 'Sci-Fi', 2024,'dune2.jpg'),
('Joker: Folie à Deux', 'Thriller', 2024,'joker2.jpg'),
('Deadpool & Wolverine', 'Action', 2024,'deadpool.jpg'),
('Inside Out 2', 'Animation', 2024,'inside.jpg'),
('The Batman', 'Action', 2022,'batman.jpg'),
('Top Gun: Maverick', 'Action', 2022,'top.jpg'),
('Everything Everywhere All at Once', 'Sci-Fi', 2022,'every.jpg'),
('Barbie', 'Comedy', 2023,'barbie.jpg');
 
 
 -- 🍿 EXTRA MOVIES (Batch 2)
INSERT INTO movies (title, genre, release_year, poster_path) VALUES
('The Batman', 'Action', 2022, 'batman.jpg'),
('Doctor Strange in the Multiverse of Madness', 'Sci-Fi', 2022, 'doctorstrange.jpg'),
('Shutter Island', 'Thriller', 2010, 'shutterisland.jpg'),
('Avatar: The Way of Water', 'Sci-Fi', 2022, 'avatar2.jpg'),
('The Shawshank Redemption', 'Drama', 1994, 'shawshank.jpg'),
('The Godfather', 'Crime', 1972, 'godfather.jpg'),
('The Wolf of Wall Street', 'Comedy', 2013, 'wolfofwallstreet.jpg'),
('Pulp Fiction', 'Crime', 1994, 'pulpfiction.jpg'),
('Whiplash', 'Drama', 2014, 'whiplash.jpg'),
('RRR', 'Action', 2022, 'rrr.jpg'),
('KGF: Chapter 2', 'Action', 2022, 'kgf2.jpg'),
('The Social Network', 'Drama', 2010, 'socialnetwork.jpg'),
('Her', 'Romance', 2013, 'her.jpg'),
('Your Name', 'Animation', 2016, 'yourname.jpg'),
('The Conjuring', 'Horror', 2013, 'conjuring.jpg'),
('Mad Max: Fury Road', 'Action', 2015, 'madmax.jpg'),
('La La Land', 'Musical', 2016, 'lalaland.jpg'),
('The Grand Budapest Hotel', 'Comedy', 2014, 'grandbudapest.jpg'),
('Django Unchained', 'Action', 2012, 'django.jpg'),
('The Irishman', 'Crime', 2019, 'irishman.jpg');

select * from users;
DELETE FROM ratings WHERE user_id IN (SELECT user_id FROM users WHERE username = 'dummy' OR email LIKE '%dummy%');



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


DELIMITER $$

CREATE PROCEDURE generate_recommendations_for_user_strict(
    IN p_user_id INT,
    IN p_limit INT,
    IN p_allow_fallback TINYINT -- 0 = strict (only user's genres), 1 = allow fallback
)
BEGIN
    DECLARE remaining_limit INT DEFAULT 0;

    -- clear previous recs
    DELETE FROM recommendations WHERE user_id = p_user_id;

    -- build user genre stats (normalize to UPPER)
    DROP TEMPORARY TABLE IF EXISTS user_genre_stats;
    CREATE TEMPORARY TABLE user_genre_stats AS
    SELECT UPPER(COALESCE(m.genre,'UNKNOWN')) AS genre,
           AVG(r.rating) AS avg_rating,
           COUNT(*) AS cnt
    FROM ratings r
    JOIN movies m ON r.movie_id = m.movie_id
    WHERE r.user_id = p_user_id
    GROUP BY UPPER(COALESCE(m.genre,'UNKNOWN'));

    -- if user has any rated genres, pick top N genres by avg_rating then count
    IF (SELECT COUNT(*) FROM user_genre_stats) > 0 THEN

        DROP TEMPORARY TABLE IF EXISTS top_user_genres;
        CREATE TEMPORARY TABLE top_user_genres AS
        SELECT genre
        FROM user_genre_stats
        ORDER BY avg_rating DESC, cnt DESC
        LIMIT 3; -- pick top 3 genres (tweak if you want)

        -- insert only movies from those genres, exclude movies already rated by the user
        INSERT INTO recommendations (user_id, movie_id, reason)
        SELECT DISTINCT p_user_id, m.movie_id,
               CONCAT('Because you liked ', COALESCE(m.genre,'Unknown'))
        FROM movies m
        LEFT JOIN ratings ur ON ur.movie_id = m.movie_id AND ur.user_id = p_user_id
        WHERE ur.movie_id IS NULL
          AND UPPER(COALESCE(m.genre,'UNKNOWN')) IN (SELECT genre FROM top_user_genres)
        ORDER BY m.avg_rating DESC, m.ratings_count DESC
        LIMIT p_limit;

        -- compute remaining
        SET remaining_limit = p_limit - (SELECT COUNT(*) FROM recommendations WHERE user_id = p_user_id);

        -- fallback only if allowed
        IF p_allow_fallback = 1 AND remaining_limit > 0 THEN
            INSERT INTO recommendations(user_id, movie_id, reason)
            SELECT p_user_id, m2.movie_id, 'Top rated fallback'
            FROM movies m2
            LEFT JOIN ratings ur2 ON ur2.movie_id = m2.movie_id AND ur2.user_id = p_user_id
            WHERE ur2.movie_id IS NULL
              AND UPPER(COALESCE(m2.genre,'UNKNOWN')) NOT IN (SELECT genre FROM top_user_genres)
              AND m2.movie_id NOT IN (SELECT movie_id FROM recommendations WHERE user_id = p_user_id)
            ORDER BY m2.avg_rating DESC, m2.ratings_count DESC
            LIMIT remaining_limit;
        END IF;

    ELSE
        -- user has no ratings — use fallback (or insert nothing if you want strict empty)
        IF p_allow_fallback = 1 THEN
            INSERT INTO recommendations(user_id, movie_id, reason)
            SELECT p_user_id, m.movie_id, 'Top rated fallback'
            FROM movies m
            WHERE m.movie_id NOT IN (SELECT movie_id FROM ratings WHERE user_id = p_user_id)
            ORDER BY m.avg_rating DESC, m.ratings_count DESC
            LIMIT p_limit;
        END IF;
    END IF;

END$$

DELIMITER ;


-- What the DB thinks are the user's genre stats:
SELECT * FROM (
  SELECT UPPER(COALESCE(m.genre,'UNKNOWN')) AS genre,
         AVG(r.rating) avg_rating,
         COUNT(*) cnt
  FROM ratings r
  JOIN movies m ON r.movie_id = m.movie_id
  WHERE r.user_id = 1029
  GROUP BY UPPER(COALESCE(m.genre,'UNKNOWN'))
) t ORDER BY avg_rating DESC, cnt DESC;

-- See what recommendations were inserted
SELECT r.*, m.title, m.genre, m.avg_rating
FROM recommendations r
JOIN movies m USING(movie_id)
WHERE r.user_id = 1030
ORDER BY r.recommended_at DESC;

SELECT * FROM recommendations WHERE user_id = 1030;

CALL generate_recommendations_for_user_v2(1030, 10);

CALL generate_recommendations_for_user_v2(1031, 15);
SELECT COUNT(*) FROM recommendations WHERE user_id = 1031;



SHOW PROCEDURE STATUS WHERE Db = 'movie_recommender';


INSERT INTO movies (title, genre, release_year, poster_path) VALUES
('Dude','Romance',2025,'dude.jpg');

INSERT INTO movies (title, genre, release_year, poster_path) VALUES
('The Notebook', 'Romance', 2004, 'the_notebook.jpg'),
('Pride and Prejudice', 'Romance', 2005, 'pride_and_prejudice.jpg'),
('Call Me by Your Name', 'Romance', 2017, 'call_me_by_your_name.jpg'),
('Titanic', 'Romance', 1997, 'titanic.jpg'),
('A Walk to Remember', 'Romance', 2002, 'a_walk_to_remember.jpg'),
('The Fault in Our Stars', 'Romance', 2014, 'fault_in_our_stars.jpg'),
('500 Days of Summer', 'Romance', 2009, '500_days_of_summer.jpg'),
('Crazy Rich Asians', 'Romance', 2018, 'crazy_rich_asians.jpg'),
('Eternal Sunshine of the Spotless Mind', 'Romance', 2004, 'eternal_sunshine.jpg');

INSERT INTO movies (title, genre, release_year, poster_path) VALUES
('The Hangover', 'Comedy', 2009, 'the_hangover.jpg'),
('Superbad', 'Comedy', 2007, 'superbad.jpg'),
('Step Brothers', 'Comedy', 2008, 'step_brothers.jpg'),
('21 Jump Street', 'Comedy', 2012, '21_jump_street.jpg'),
('Dumb and Dumber', 'Comedy', 1994, 'dumb_and_dumber.jpg'),
('The Mask', 'Comedy', 1994, 'the_mask.jpg'),
('Mean Girls', 'Comedy', 2004, 'mean_girls.jpg'),
('Jumanji: Welcome to the Jungle', 'Comedy', 2017, 'jumanji_welcome.jpg'),
('The Nice Guys', 'Comedy', 2016, 'the_nice_guys.jpg');

