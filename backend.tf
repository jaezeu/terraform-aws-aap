terraform {
  backend "s3" {
    bucket = "sctp-core-tfstate"
    key    = "aap.tfstate"
    region = "ap-southeast-1"
  }
}