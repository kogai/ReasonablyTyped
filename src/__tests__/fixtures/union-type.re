type union_of_number_or_string =
  | Number float
  | String string;

type number_or_string;

external number_or_string : union_of_number_or_string => number_or_string =
  "Array.prototype.shift.call" [@@bs.val];

external double : x::number_or_string => float = "" [@@bs.module "union-type"];
