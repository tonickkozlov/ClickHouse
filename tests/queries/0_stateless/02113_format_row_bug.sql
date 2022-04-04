-- Tags: no-fasttest

select formatRow('Native', number, toDate(number)) from numbers(5); -- { serverError 36 }
