--this is a test document!!!

CREATE TABLE employees (
    id INT PRIMARY KEY,
    name VARCHAR(50) NOT NULL,
    department VARCHAR(50),
    hire_date DATE
);


INSERT INTO employees (id, name, department, hire_date) 
VALUES 
    (1, 'Alice Smith', 'Engineering', '2025-03-15'),
    (2, 'Bob Jones', 'Marketing', '2026-01-10'),
    (3, 'Charlie Brown', 'Sales', '2026-08-22');



SELECT * FROM employees;